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

    # Fallbacks from MinKNOW 25.09 sequencing_channel_states.toml.
    # Acquisition metadata takes precedence over these defaults.
    private CHANNEL_APPEARANCES = {
      nil                    => {'.', MUTED},
      "strand"               => {'S', "#00ff00"},
      "pore"                 => {'P', "#00cc00"},
      "adapter"              => {'A', "#ede797"},
      "no_pore"              => {'-', "#90c6e7"},
      "unblocking"           => {'U', "#a53f97"},
      "unavailable"          => {'!', "#54b8b1"},
      "saturated"            => {'!', "#68767e"},
      "multiple"             => {'M', "#f57e20"},
      "unknown_negative"     => {'?', "#b5aea7"},
      "unknown_positive"     => {'?', "#0084a9"},
      "zero"                 => {'0', "#4da9c3"},
      "disabled"             => {'x', "#ccd5d8"},
      "locked"               => {'x', "#ccd5d8"},
      "pending_mux_change"   => {'~', MUTED},
      "pending_manual_reset" => {'~', MUTED},
    }

    def self.channel_appearance(name : String?) : Tuple(Char, String)
      CHANNEL_APPEARANCES[name]? || {'?', MUTED}
    end

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
