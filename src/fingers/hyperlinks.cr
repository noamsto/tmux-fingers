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
            unless new_uri.empty?
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

  # Maps a non-joined capture (which re-opens links on every physical row) onto
  # the joined (-J) lines the hinter matches against.
  def self.resolve(raw : String, lines : Array(String), pane_width : Int32) : Array(Link)
    rows, spans = parse(raw)
    return [] of Link if spans.empty?

    origins = row_origins(rows, lines, pane_width)
    return [] of Link unless origins

    joined = [] of Span
    spans.each do |span|
      line, offset = origins[span.row]? || (return [] of Link)
      remapped = Span.new(span.uri, line, span.col_start + offset, span.col_end + offset)
      previous = joined.last?

      if previous && previous.uri == remapped.uri && previous.row == line &&
         previous.col_end == remapped.col_start
        joined[-1] = Span.new(previous.uri, line, previous.col_start, remapped.col_end)
      else
        joined << remapped
      end
    end

    group(joined, lines)
  end

  private def self.row_origins(rows : Array(String), lines : Array(String), pane_width : Int32) : Array(Tuple(Int32, Int32))?
    origins = [] of Tuple(Int32, Int32)
    line_index = 0
    pos = 0

    rows.each do |text|
      line = lines[line_index]?
      return origins if line.nil? && text.empty?
      return nil unless line
      return nil if pos + text.size > line.size || line[pos, text.size] != text

      origins << {line_index, pos}

      if pos + text.size >= line.rstrip(' ').size
        line_index += 1
        pos = 0
      else
        pos += text.size + (pane_width - cells(text))
      end
    end

    origins
  end

  private def self.cells(text : String) : Int32
    text.each_char.sum { |char| wide?(char) ? 2 : 1 }
  end

  private def self.wide?(char : Char) : Bool
    code = char.ord
    (0x1100..0x115F).includes?(code) || (0x2E80..0xA4CF).includes?(code) ||
      (0xAC00..0xD7A3).includes?(code) || (0xF900..0xFAFF).includes?(code) ||
      (0xFE30..0xFE6F).includes?(code) || (0xFF00..0xFF60).includes?(code) ||
      (0xFFE0..0xFFE6).includes?(code) || (0x1F300..0x1FAFF).includes?(code) ||
      (0x20000..0x3FFFD).includes?(code)
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
