require "spec"
require "../../spec_helper.cr"
require "../../../src/fingers/hinter"
require "../../../src/fingers/state"
require "../../../src/fingers/config"
require "../../../src/fingers/hyperlinks"

record StateDouble, selected_hints : Array(String)

class TextOutput < ::Fingers::Printer
  def initialize
    @contents = ""
  end

  def print(msg)
    self.contents += msg
  end

  def flush
  end

  property :contents
end

def generate_lines
  input = 50.times.map do
    10.times.map do
      rand.to_s.split(".").last[0..15].rjust(16, '0')
    end.join(" ")
  end.join("\n")
end

describe Fingers::Hinter do
  it "works in a grid of lines" do
    width = 100
    input = generate_lines
    output = TextOutput.new

    patterns = Fingers::BUILTIN_PATTERNS.values.to_a
    alphabet = "asdf".split("")

    hinter = Fingers::Hinter.new(
      input: input.split("\n"),
      width: width,
      patterns: patterns,
      state: ::Fingers::State.new,
      alphabet: alphabet,
      output: output,
    )
  end

  it "only highlights captured groups" do
    width = 100
    input = "
On branch ruby-rewrite-more-like-crystal-rewrite-amirite
Your branch is up to date with 'origin/ruby-rewrite-more-like-crystal-rewrite-amirite'.

Changes to be committed:
  (use \"git restore --staged <file>...\" to unstage)
        modified:   spec/lib/fingers/match_formatter_spec.cr

Changes not staged for commit:
  (use \"git add <file>...\" to update what will be committed)
  (use \"git restore <file>...\" to discard changes in working directory)
        modified:   .gitignore
        modified:   spec/lib/fingers/hinter_spec.cr
        modified:   spec/spec_helper.cr
        modified:   src/fingers/cli.cr
        modified:   src/fingers/dirs.cr
        modified:   src/fingers/match_formatter.cr
    "
    output = TextOutput.new

    patterns = Fingers::BUILTIN_PATTERNS.values.to_a
    patterns << "On branch (?<capture>.*)"
    alphabet = "asdf".split("")

    hinter = Fingers::Hinter.new(
      input: input.split("\n"),
      width: width,
      patterns: patterns,
      state: ::Fingers::State.new,
      alphabet: alphabet,
      output: output,
    )
  end

  it "only reuses hints when allow duplicates is false" do
    width = 100
    output = TextOutput.new

    patterns = Fingers::BUILTIN_PATTERNS.values.to_a
    alphabet = "asdf".split("")

    input = "
          modified:   src/fingers/cli.cr
          modified:   src/fingers/cli.cr
          modified:   src/fingers/cli.cr
    "

    hinter = Fingers::Hinter.new(
      input: input.split("\n"),
      width: width,
      patterns: patterns,
      state: ::Fingers::State.new,
      alphabet: alphabet,
      output: output,
      reuse_hints: false
    )

    hinter.run
  end

  it "can rerender when not reusing hints" do
    width = 100
    output = TextOutput.new

    patterns = Fingers::BUILTIN_PATTERNS.values.to_a
    alphabet = "asdf".split("")

    input = "
          modified:   src/fingers/cli.cr
          modified:   src/fingers/cli.cr
          modified:   src/fingers/cli.cr
    "

    hinter = Fingers::Hinter.new(
      input: input.split("\n"),
      width: width,
      patterns: patterns,
      state: ::Fingers::State.new,
      alphabet: alphabet,
      output: output,
      reuse_hints: false
    )

    hinter.run
    hinter.run
  end

  context "with hyperlinks" do
    uri = "https://example.com/some/long/path"
    never = ["(?!)"]
    hint_texts = ->(hinter : Fingers::Hinter) do
      "asdf".chars.compact_map { |h| hinter.lookup(h.to_s).try { |t| {h.to_s, t.text} } }.to_h
    end
    link_hinter = ->(rows : Array(String), links : Array(Fingers::Hyperlinks::Link), output : TextOutput, patterns : Array(String), hint_position : String) do
      Fingers::Hinter.new(
        input: rows,
        width: 40,
        patterns: patterns,
        state: ::Fingers::State.new,
        alphabet: "asdf".split(""),
        output: output,
        formatter: Fingers::MatchFormatter.new(
          hint_style: "<H>",
          highlight_style: "<L>",
          selected_hint_style: "<SH>",
          selected_highlight_style: "<SL>",
          backdrop_style: "<B>",
          hint_position: hint_position,
          reset_sequence: "<R>"
        ),
        reuse_hints: true,
        hyperlinks: links
      )
    end

    split_rows = ["see https://example.com/some/lo", "ng/path now"]
    split_link = ->{
      Fingers::Hyperlinks::Link.new(uri, [
        Fingers::Hyperlinks::Segment.new(0, 4, 31),
        Fingers::Hyperlinks::Segment.new(1, 0, 7),
      ])
    }

    it "hints a link split across rows once, with the full uri as target" do
      output = TextOutput.new
      hinter = link_hinter.call(split_rows, [split_link.call], output, never, "left")
      hinter.run

      hint_texts.call(hinter).values.should eq([uri])
      hint, _ = hint_texts.call(hinter).first
      hinter.lookup(hint).not_nil!.offset.should eq({0, 4})
      output.contents.scan("<H>").size.should eq(1)
      output.contents.should contain("<L>ng/path<R><B>")
    end

    it "hints a link and a regular match on the same row" do
      output = TextOutput.new
      rows = ["ip 10.0.0.1 https://example.com/a"]
      link = Fingers::Hyperlinks::Link.new("https://example.com/a", [Fingers::Hyperlinks::Segment.new(0, 12, 33)])
      hinter = link_hinter.call(rows, [link], output, [Fingers::BUILTIN_PATTERNS["ip"]], "left")
      hinter.run

      hint_texts.call(hinter).values.sort.should eq(["10.0.0.1", "https://example.com/a"])
    end

    it "drops regex matches overlapping link cells" do
      output = TextOutput.new
      hinter = link_hinter.call(split_rows, [split_link.call], output, [Fingers::BUILTIN_PATTERNS["url"]], "left")
      hinter.run

      output.contents.scan("<H>").size.should eq(1)
      hint_texts.call(hinter).values.should eq([uri])
    end

    it "supports hint position right" do
      output = TextOutput.new
      hinter = link_hinter.call(split_rows, [split_link.call], output, never, "right")
      hinter.run

      hint, _ = hint_texts.call(hinter).first
      output.contents.should contain("<R><L>https://example.com/some/l<R><H>#{hint}<R>")
    end

    it "reuses the hint for the same uri" do
      output = TextOutput.new
      rows = ["https://example.com/a", "https://example.com/a"]
      links = [0, 1].map { |r| Fingers::Hyperlinks::Link.new("https://example.com/a", [Fingers::Hyperlinks::Segment.new(r, 0, 21)]) }
      hinter = link_hinter.call(rows, links, output, never, "left")
      hinter.run

      hint_texts.call(hinter).size.should eq(1)
      hint, _ = hint_texts.call(hinter).first
      output.contents.scan("<H>#{hint}<R>").size.should eq(2)
    end
  end
end
