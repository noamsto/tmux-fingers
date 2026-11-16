require "spec"
require "../../../src/fingers/hyperlinks"

URI_FULL = "https://example.com/very/long/path/to/thing"

def osc(uri : String, params = "", st = "\e\\")
  "\e]8;#{params};#{uri}#{st}"
end

describe Fingers::Hyperlinks do
  describe ".parse" do
    it "extracts rows and spans from a wrapped link" do
      raw = "a #{osc(URI_FULL)}https://example.com/very/#{osc("")}\n" \
            "#{osc(URI_FULL)}/long/path/to/thing#{osc("")} b"
      rows, spans = Fingers::Hyperlinks.parse(raw)

      rows.should eq ["a https://example.com/very/", "/long/path/to/thing b"]
      spans.should eq [
        Fingers::Hyperlinks::Span.new(URI_FULL, 0, 2, 27),
        Fingers::Hyperlinks::Span.new(URI_FULL, 1, 0, 19),
      ]
    end

    it "does not shift columns for SGR escapes" do
      raw = "\e[31mab #{osc("u")}\e[1mcd\e[0mef#{osc("")}\e[0m"
      rows, spans = Fingers::Hyperlinks.parse(raw)

      rows.should eq ["ab cdef"]
      spans.should eq [Fingers::Hyperlinks::Span.new("u", 0, 3, 7)]
    end

    it "accepts BEL-terminated OSC 8" do
      rows, spans = Fingers::Hyperlinks.parse("x #{osc("u", st: "\a")}link#{osc("", st: "\a")}")

      rows.should eq ["x link"]
      spans.should eq [Fingers::Hyperlinks::Span.new("u", 0, 2, 6)]
    end

    it "ignores id= params" do
      rows, spans = Fingers::Hyperlinks.parse("#{osc("u", "id=x")}link#{osc("", "id=x")}")

      rows.should eq ["link"]
      spans.should eq [Fingers::Hyperlinks::Span.new("u", 0, 0, 4)]
    end

    it "counts chars, not bytes" do
      _, spans = Fingers::Hyperlinks.parse("日本#{osc("u")}ab#{osc("")}")

      spans.should eq [Fingers::Hyperlinks::Span.new("u", 0, 2, 4)]
    end

    it "ends an open link at row end without carrying state" do
      rows, spans = Fingers::Hyperlinks.parse("#{osc("u")}ab\ncd")

      rows.should eq ["ab", "cd"]
      spans.should eq [Fingers::Hyperlinks::Span.new("u", 0, 0, 2)]
    end

    it "drops zero-width spans and strips SO/SI" do
      rows, spans = Fingers::Hyperlinks.parse("a#{osc("u")}#{osc("")}\u000e\u000fb")

      rows.should eq ["ab"]
      spans.should be_empty
    end
  end

  describe ".resolve" do
    it "links a hard-wrapped link from a non-joined capture" do
      raw = "a #{osc(URI_FULL)}https://example.com/very/#{osc("")}\n" \
            "#{osc(URI_FULL)}/long/path/to/thing#{osc("")} b 10.0.0.1\n"
      lines = ["a https://example.com/very/", "/long/path/to/thing b 10.0.0.1"]
      links = Fingers::Hyperlinks.resolve(raw, lines, 80)

      links.size.should eq 1
      links[0].uri.should eq URI_FULL
      links[0].segments.should eq [
        Fingers::Hyperlinks::Segment.new(0, 2, 27),
        Fingers::Hyperlinks::Segment.new(1, 0, 19),
      ]
    end

    it "joins a link soft-wrapped at the pane width into one segment" do
      uri = "https://ex.com/aaaa/bbbb"
      raw = "see #{osc(uri)}https://ex.com/a#{osc("")}\n#{osc(uri)}aaa/bbbb#{osc("")} end\n"
      lines = ["see https://ex.com/aaaa/bbbb end"]
      links = Fingers::Hyperlinks.resolve(raw, lines, 20)

      links.size.should eq 1
      links[0].uri.should eq uri
      links[0].segments.should eq [Fingers::Hyperlinks::Segment.new(0, 4, 28)]
    end

    it "stays aligned on lines after a soft-wrapped one" do
      raw = "aaaaaaaaaaaaaaaaaaaa\n bbbb\ngo #{osc("u")}https://x.io/p#{osc("")}\n"
      lines = ["aaaaaaaaaaaaaaaaaaaa bbbb", "go https://x.io/p"]
      links = Fingers::Hyperlinks.resolve(raw, lines, 20)

      links.size.should eq 1
      links[0].segments.should eq [Fingers::Hyperlinks::Segment.new(1, 3, 17)]
    end

    it "returns nothing when raw and lines disagree" do
      raw = "#{osc("u")}hello#{osc("")}\n"

      Fingers::Hyperlinks.resolve(raw, ["goodbye"], 80).should be_empty
    end

    it "returns nothing without links" do
      Fingers::Hyperlinks.resolve("plain\ntext\n", ["plain", "text"], 80).should be_empty
    end
  end

  describe ".group" do
    span = ->(uri : String, row : Int32, s : Int32, e : Int32) { Fingers::Hyperlinks::Span.new(uri, row, s, e) }

    it "merges a link split across two rows" do
      rows = ["a https://example.com/very/", "/long/path/to/thing b"]
      links = Fingers::Hyperlinks.group([span.call(URI_FULL, 0, 2, 27), span.call(URI_FULL, 1, 0, 19)], rows)

      links.size.should eq 1
      links[0].uri.should eq URI_FULL
      links[0].segments.should eq [
        Fingers::Hyperlinks::Segment.new(0, 2, 27),
        Fingers::Hyperlinks::Segment.new(1, 0, 19),
      ]
    end

    it "keeps non-adjacent rows separate" do
      rows = ["ab", "x", "cd"]
      links = Fingers::Hyperlinks.group([span.call("u", 0, 0, 2), span.call("u", 2, 0, 2)], rows)

      links.size.should eq 2
    end

    it "merges when the second row is indented" do
      rows = ["ab", "   cd"]
      links = Fingers::Hyperlinks.group([span.call("u", 0, 0, 2), span.call("u", 1, 3, 5)], rows)

      links.size.should eq 1
      links[0].segments.size.should eq 2
    end

    it "ignores trailing spaces when finding the row end" do
      rows = ["ab   ", "cd"]
      links = Fingers::Hyperlinks.group([span.call("u", 0, 0, 2), span.call("u", 1, 0, 2)], rows)

      links.size.should eq 1
    end

    it "does not merge when the first span does not touch row end" do
      rows = ["ab cd", "ef"]
      links = Fingers::Hyperlinks.group([span.call("u", 0, 0, 2), span.call("u", 1, 0, 2)], rows)

      links.size.should eq 2
    end

    it "does not merge different URIs or same-row spans" do
      rows = ["abcd", "ef"]
      Fingers::Hyperlinks.group([span.call("u", 0, 0, 4), span.call("v", 1, 0, 2)], rows).size.should eq 2
      Fingers::Hyperlinks.group([span.call("u", 0, 0, 2), span.call("u", 0, 2, 4)], rows).size.should eq 2
    end
  end
end
