require "spec"
require "../../src/tmux"

describe Tmux do
  describe ".supports_hyperlinks?" do
    it "is false for an empty version" do
      Tmux.supports_hyperlinks?("").should be_false
    end

    it "is false before 3.4" do
      Tmux.supports_hyperlinks?("3.3a").should be_false
    end

    it "is true from 3.4" do
      Tmux.supports_hyperlinks?("3.4").should be_true
      Tmux.supports_hyperlinks?("3.5a").should be_true
    end
  end

  describe ".escape_format" do
    it "doubles # so display-message prints it literally" do
      Tmux.escape_format("a\#{b}\#(id) \#[bold]").should eq "a#\#{b}##(id) ##[bold]"
    end
  end
end
