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
end
