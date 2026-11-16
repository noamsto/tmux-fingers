module Fingers::Hyperlinks
  struct Segment
    getter row : Int32
    getter col_start : Int32
    getter col_end : Int32

    def initialize(@row, @col_start, @col_end)
    end
  end

  struct Span
    getter uri : String
    getter row : Int32
    getter col_start : Int32
    getter col_end : Int32

    def initialize(@uri, @row, @col_start, @col_end)
    end
  end

  class Link
    getter uri : String
    getter segments : Array(Segment)

    def initialize(@uri, @segments)
    end
  end

  def self.parse(raw : String) : Tuple(Array(String), Array(Span))
    rows = [] of String
    spans = [] of Span
    row = String::Builder.new
    col = 0
    uri : String? = nil
    start = 0

    close_span = ->(row_index : Int32, end_col : Int32) do
      open_uri = uri
      spans << Span.new(open_uri, row_index, start, end_col) if open_uri && end_col > start
      uri = nil
    end

    chars = raw.chars
    i = 0
    while i < chars.size
      char = chars[i]
      i += 1

      case char
      when '\n'
        close_span.call(rows.size, col)
        rows << row.to_s
        row = String::Builder.new
        col = 0
      when '\u000e', '\u000f'
        next
      when '\e'
        kind = chars[i]?
        i += 1
        case kind
        when '['
          while (c = chars[i]?) && !(0x40..0x7e).includes?(c.ord)
            i += 1
          end
          i += 1
        when ']'
          body = String::Builder.new
          while (c = chars[i]?)
            break if c == '\a'
            break if c == '\e' && chars[i + 1]? == '\\'
            body << c
            i += 1
          end
          i += chars[i]? == '\a' ? 1 : 2
          body = body.to_s
          if body.starts_with?("8;")
            close_span.call(rows.size, col)
            new_uri = body.split(';', 3)[2]? || ""
            unless new_uri.empty? || new_uri.each_char.any? { |c| c.whitespace? || c.control? }
              uri = new_uri
              start = col
            end
          end
        end
      else
        row << char
        col += 1
      end
    end

    close_span.call(rows.size, col)
    rows << row.to_s

    {rows, spans}
  end

  # Maps a non-joined capture onto the joined (-J) lines the hinter matches
  # against. tmux re-opens a link on hard-wrapped rows but not on soft-wrapped
  # continuation rows, so a span ending at a soft wrap is extended to the full URI.
  def self.resolve(raw : String, lines : Array(String)) : Array(Link)
    rows, spans = parse(raw)
    return [] of Link if spans.empty?

    origins = row_origins(rows, lines)
    return [] of Link unless origins

    joined = [] of Span
    spans.each do |span|
      line, offset = origins[span.row]? || (return [] of Link)
      col_end = span.col_end + offset
      soft_wrapped = origins[span.row + 1]?.try(&.[0]) == line

      if soft_wrapped && span.col_end == rows[span.row].size
        start = span.col_start + offset
        extended = start + common_prefix_size(lines[line], start, span.uri)
        col_end = extended if extended > col_end
      end

      remapped = Span.new(span.uri, line, span.col_start + offset, col_end)
      previous = joined.last?

      if previous && previous.uri == remapped.uri && previous.row == line &&
         remapped.col_start <= previous.col_end
        joined[-1] = Span.new(previous.uri, line, previous.col_start, {previous.col_end, remapped.col_end}.max)
      else
        joined << remapped
      end
    end

    joined.each_index do |index|
      current = joined[index]
      following = joined[index + 1]?
      next unless following && following.row == current.row && following.col_start < current.col_end

      joined[index] = Span.new(current.uri, current.row, current.col_start, following.col_start)
    end

    group(joined, lines)
  end

  private def self.common_prefix_size(line : String, from : Int32, uri : String) : Int32
    size = 0
    while (char = line[from + size]?) && char == uri[size]?
      size += 1
    end
    size
  end

  # Soft-wrapped rows are separated in the joined line by at most the padding
  # tmux inserted (spaces, e.g. a tab filling to a tab stop), so the next row
  # origin is the first offset past the row where the next row's text matches.
  private def self.row_origins(rows : Array(String), lines : Array(String)) : Array(Tuple(Int32, Int32))?
    origins = [] of Tuple(Int32, Int32)
    line_index = 0
    pos = 0

    rows.each_with_index do |text, index|
      line = lines[line_index]?
      return origins if line.nil? && text.empty?
      return nil unless line
      return nil if pos + text.size > line.size || line[pos, text.size] != text

      origins << {line_index, pos}

      row_end = pos + text.size
      if row_end >= line.rstrip(' ').size
        line_index += 1
        pos = 0
      else
        pos = next_row_origin(line, row_end, rows[index + 1]?) || (return nil)
      end
    end

    origins
  end

  private def self.next_row_origin(line : String, from : Int32, next_text : String?) : Int32?
    return from if next_text.nil? || next_text.empty?

    pos = from
    while pos + next_text.size <= line.size
      return pos if line[pos, next_text.size] == next_text
      return nil unless line[pos] == ' '
      pos += 1
    end
  end

  def self.group(spans : Array(Span), rows : Array(String)) : Array(Link)
    links = [] of Link

    spans.each do |span|
      previous = links.last?.try(&.segments.last)
      link = links.last?

      if link && previous && link.uri == span.uri &&
         span.row == previous.row + 1 &&
         previous.col_end == rows[previous.row].rstrip(' ').size
        link.segments << Segment.new(span.row, span.col_start, span.col_end)
      else
        links << Link.new(span.uri, [Segment.new(span.row, span.col_start, span.col_end)])
      end
    end

    links
  end
end
