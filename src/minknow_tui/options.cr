require "option_parser"

module MinknowTui
  class Options
    property host = ENV["MINKNOW_HOST"]? || "localhost"
    property port = 9501
    property explicit_port = false
    property demo = false
    property exit_requested = false

    def initialize(args = ARGV, output : IO = STDOUT)
      if port = ENV["MINKNOW_PORT"]?
        self.port = parse_port(port)
        @explicit_port = true
      end
      OptionParser.parse(args) do |parser|
        parser.banner = "Usage: minknow-tui [--host HOST] [--port PORT] [--demo]"
        parser.on("--host HOST", "MinKNOW Manager host (default: localhost)") { |v| @host = v }
        parser.on("--port PORT", "Manager port; disables automatic 9502 fallback") do |v|
          @port = parse_port(v)
          @explicit_port = true
        end
        parser.on("--demo", "Monitor simulated data without connecting to MinKNOW") { @demo = true }
        parser.on("-h", "--help", "Show help") { output.puts parser; @exit_requested = true }
        parser.on("--version", "Show version") { output.puts VERSION; @exit_requested = true }
        parser.invalid_option { |flag| raise ArgumentError.new("Unknown option: #{flag}") }
        parser.unknown_args { |args| raise ArgumentError.new("Unexpected arguments: #{args.join(" ")}") unless args.empty? }
      end
      raise ArgumentError.new("Host must not be empty") if @host.empty?
    end

    private def parse_port(value : String) : Int32
      number = value.to_i?
      raise ArgumentError.new("Port must be between 1 and 65535") unless number && (1..65535).includes?(number)
      number
    end
  end
end
