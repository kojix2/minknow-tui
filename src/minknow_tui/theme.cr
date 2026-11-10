module MinknowTui
  # Green leads the interface; turquoise identifies secondary data. These are
  # application colors inspired by Nanopore, not an official brand palette.
  module Theme
    BACKGROUND = "#0d1915"
    SURFACE    = "#152a20"
    TEXT       = "#dcebe3"
    MUTED      = "#88a396"
    BORDER     = "#355846"
    GREEN      = "#52d687"
    TURQUOISE  = "#42c7b7"
    WARNING    = "#e2bc66"
    ERROR      = "#ef7a78"

    STYLESHEET = <<-CSS
      Box {
        color: #{TEXT}; background-color: transparent; border-color: #{BORDER};
      }
      Box:selected {
        color: #{BACKGROUND}; background-color: #{GREEN};
      }
      ListTable, Log { border: solid; }
      ListTable:focus, Log:focus, List:focus { border-color: #{GREEN}; }
      ListTable::header {
        color: #{MUTED}; background-color: #{SURFACE};
      }
      ListTable:selected, List:selected, CommandBar:selected {
        color: #{BACKGROUND}; background-color: #{GREEN};
      }
      ListTable::label, Log::label, Dialog::label { color: #{GREEN}; border: none; }
      Dialog { border: solid; border-color: #{GREEN}; }
      TabWidget { color: #{GREEN}; }
      CommandBar::prefix { color: #{TURQUOISE}; }
      CSS
  end
end
