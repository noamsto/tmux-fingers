require "../huffman"
require "./config"
require "./hyperlinks"
require "./match_formatter"
require "./types"

module Fingers
  struct Target
    property text : String
    property hint : String
    property offset : Tuple(Int32, Int32)

    def initialize(@text, @hint, @offset)
    end
  end

  class Hinter
    @formatter : Formatter
    @patterns : Array(String)
    @alphabet : Array(String)
    @pattern : Regex | Nil
    @hints : Array(String) | Nil
    @n_matches : Int32 | Nil
    @reuse_hints : Bool

    def initialize(
      input : Array(String),
      width : Int32,
      state : Fingers::State,
      output : Printer,
      patterns = Fingers.config.patterns,
      alphabet = Fingers.config.alphabet,
      huffman = Huffman.new,
      formatter = ::Fingers::MatchFormatter.new,
      reuse_hints = false,
      hyperlinks : Array(Hyperlinks::Link) = [] of Hyperlinks::Link
    )
      @lines = input
      @width = width
      @target_by_hint = {} of String => Target
      @target_by_text = {} of String => Target
      @state = state
      @output = output
      @formatter = formatter
      @huffman = huffman
      @patterns = patterns
      @alphabet = alphabet
      @reuse_hints = reuse_hints
      @hyperlinks = hyperlinks
      @segments_by_row = {} of Int32 => Array({Hyperlinks::Link, Hyperlinks::Segment})
      hyperlinks.each do |link|
        link.segments.each do |segment|
          (@segments_by_row[segment.row] ||= [] of {Hyperlinks::Link, Hyperlinks::Segment}) << {link, segment}
        end
      end
      @link_renders = {} of Hyperlinks::Link => {String, Bool}
    end

    def run
      regenerate_hints!
      lines[0..-2].each_with_index { |line, index| process_line(line, index, "\n") }
      process_line(lines[-1], lines.size - 1, "")

      output.flush
    end

    def lookup(hint) : Target | Nil
      target_by_hint.fetch(hint) { nil }
    end

    # private

    private getter :hints,
      :hints_by_text,
      :offsets_by_hint,
      :input,
      :lookup_table,
      :width,
      :state,
      :formatter,
      :huffman,
      :output,
      :patterns,
      :alphabet,
      :reuse_hints,
      :target_by_hint,
      :target_by_text,
      :hyperlinks,
      :segments_by_row,
      :link_renders

    def process_line(line, line_index, ending)
      tab_positions = tab_positions_for(line)
      result = splice_edits(line, line_index)
      initial_length = result.size
      result = expand_tabs(result, tab_positions)
      tab_correction = result.size - initial_length

      result = Fingers.config.backdrop_style + result
      double_width_correction = ((line.bytesize - line.size) / 3).round.to_i
      padding_amount = (width - line.size - double_width_correction - tab_correction)
      padding = padding_amount > 0 ? " " * padding_amount : ""
      output.print(result + padding + ending)
    end

    def splice_edits(line, line_index)
      segments = segments_by_row[line_index]? || [] of {Hyperlinks::Link, Hyperlinks::Segment}
      matches = line.scan(pattern).reject { |m| overlaps_link?(line_index, m.begin(0), m.end(0)) }
      result = String::Builder.new
      cursor = 0
      match_index = 0
      segment_index = 0

      while match_index < matches.size || segment_index < segments.size
        match = matches[match_index]?
        link_segment = segments[segment_index]?

        if match && (link_segment.nil? || match.begin(0) < link_segment[1].col_start)
          result << line[cursor...match.begin(0)] << replace(match, line_index)
          cursor = match.end(0)
          match_index += 1
        else
          link, segment = link_segment.not_nil!
          result << line[cursor...segment.col_start] << replace_link(link, segment, line)
          cursor = segment.col_end
          segment_index += 1
        end
      end

      result << line[cursor..]
      result.to_s
    end

    def overlaps_link?(line_index, match_begin, match_end)
      segments = segments_by_row[line_index]?
      return false unless segments

      segments.any? { |_, segment| segment.col_start < match_end && match_begin < segment.col_end }
    end

    def replace_link(link, segment, line)
      text = line[segment.col_start...segment.col_end]
      first = !link_renders.has_key?(link)

      link_renders[link] = start_link(link, text) if first
      hint, visible = link_renders[link]

      return text unless visible

      selected = state.selected_hints.includes?(hint)

      if first
        formatter.format(hint: hint, highlight: text, selected: selected, offset: nil)
      else
        formatter.format_continuation(highlight: text, selected: selected)
      end
    end

    def start_link(link, first_text)
      hint = hint_for_text(link.uri)

      if hint.size > first_text.size
        hints.push(hint)
        return {hint, false}
      end

      first = link.segments.first
      build_target(link.uri, hint, {first.row, first.col_start})

      {hint, state.input.empty? || hint.starts_with?(state.input)}
    end

    def pattern : Regex
      @pattern ||= Regex.new("(#{patterns.join('|')})")
    end

    def hints : Array(String)
      return @hints.as(Array(String)) if !@hints.nil?

      regenerate_hints!

      @hints.as(Array(String))
    end

    def regenerate_hints!
      @hints = huffman.generate_hints(alphabet: alphabet.clone, n: n_matches)
      @target_by_hint.clear
      @target_by_text.clear
      @link_renders.clear
    end

    def replace(match, line_index)
      text = match[0]

      captured_text = captured_text_for_match(match)
      relative_capture_offset = relative_capture_offset_for_match(match, captured_text)

      absolute_offset = {
        line_index,
        match.begin(0) + (relative_capture_offset ? relative_capture_offset[0] : 0)
      }

      hint = hint_for_text(captured_text)

      # hint is longer than highlighted text, put it back in hint stack
      if hint.size > captured_text.size
        hints.push(hint)
        return text
      end

      build_target(captured_text, hint, absolute_offset)

      if !state.input.empty? && !hint.starts_with?(state.input)
        return text
      end

      formatter.format(
        hint: hint,
        highlight: text,
        selected: state.selected_hints.includes?(hint),
        offset: relative_capture_offset
      )
    end

    def captured_text_for_match(match)
      match["match"]? || match[0]
    end

    def hint_for_text(text)
      return pop_hint! unless reuse_hints

      target = target_by_text[text]?

      if target.nil?
        return pop_hint!
      end

      target.hint
    end

    def pop_hint! : String
      hint = hints.pop?

      if hint.nil?
        raise "Too many matches"
      end

      hint
    end

    def relative_capture_offset_for_match(match, captured_text)
      return nil unless match["match"]?

      match_start, match_end = {match.begin(0), match.end(0)}
      capture_start, capture_end = find_capture_offset(match).not_nil!
      {capture_start - match_start, captured_text.size}
    end

    def build_target(text, hint, offset)
      target = Target.new(text, hint, offset)

      target_by_hint[hint] = target
      target_by_text[text] = target

      target
    end

    def find_capture_offset(match : Regex::MatchData) : Tuple(Int32, Int32) | Nil
      index = capture_indices.find { |i| match[i]? }

      return nil unless index

      {match.begin(index), match.end(index)}
    end

    getter capture_indices : Array(Int32) do
      pattern.name_table.compact_map { |k, v| v == "match" ? k : nil }
    end

    def n_matches : Int32
      return @n_matches.as(Int32) if !@n_matches.nil?

      if reuse_hints
        @n_matches = count_unique_matches
      else
        @n_matches = count_matches
      end
    end

    def count_unique_matches
      match_set = Set(String).new

      lines.each_with_index do |line, index|
        line.scan(pattern) do |match|
          next if overlaps_link?(index, match.begin(0), match.end(0))
          match_set.add(captured_text_for_match(match))
        end
      end

      hyperlinks.each { |link| match_set.add(link.uri) }

      @n_matches = match_set.size

      match_set.size
    end

    def count_matches
      result = hyperlinks.size

      lines.each_with_index do |line, index|
        line.scan(pattern) do |match|
          result += 1 unless overlaps_link?(index, match.begin(0), match.end(0))
        end
      end

      result
    end

    def tab_positions_for(line)
      positions = [] of Int32
      offset = 0

      loop do
        index = line.index("\t", offset)

        break unless index
        positions << index
        offset = index + 1
      end

      positions
    end

    def expand_tabs(line, tab_positions)
      correction = 0
      line.gsub(/\t/) do |_|
        tab_position = tab_positions.shift?
        next "\t" unless tab_position
        spaces = 8 - ((tab_position + correction) % 8)
        correction += spaces - 1
        " " * spaces
      end
    end

    private property lines : Array(String)
  end
end
