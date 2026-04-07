require "lipgloss"

module Manifold
  module UI
    module_function

    HEADER_STYLE = Lipgloss::Style.new
      .bold(true)
      .foreground("#FAFAFA")
      .background("#7D56F4")
      .border(:rounded)
      .border_foreground("#874BFD")
      .padding(0, 2)
      .align_horizontal(:center)

    STEP_STYLE = Lipgloss::Style.new
      .bold(true)
      .foreground("#04B575")

    INFO_STYLE = Lipgloss::Style.new
      .foreground("#999999")

    WARN_STYLE = Lipgloss::Style.new
      .bold(true)
      .foreground("#FFCC00")

    ERROR_STYLE = Lipgloss::Style.new
      .bold(true)
      .foreground("#FF4444")

    LABEL_STYLE = Lipgloss::Style.new
      .bold(true)
      .foreground("#FAFAFA")

    VALUE_STYLE = Lipgloss::Style.new
      .foreground("#999999")

    def header(text)
      puts HEADER_STYLE.render(text)
    end

    def step(text)
      puts STEP_STYLE.render("==> #{text}")
    end

    def info(text)
      puts INFO_STYLE.render(text)
    end

    def warn(text)
      $stderr.puts WARN_STYLE.render(text)
    end

    def error(text)
      $stderr.puts ERROR_STYLE.render(text)
    end

    def newline
      puts
    end

    def key_value_list(pairs)
      pairs.each do |label, value|
        print LABEL_STYLE.render("  #{label}: ")
        puts VALUE_STYLE.render(value.to_s)
      end
    end
  end
end
