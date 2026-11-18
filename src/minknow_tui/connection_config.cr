require "minknow"

module MinknowTui
  class ConnectionConfig < Minknow::ConnectionConfig
    class InvalidCAPath < ArgumentError; end

    # Keep the shard's TLS setup and platform-specific CA paths, but only
    # allow those paths to extend trust for an explicitly local endpoint.
    private def resolved_ca_certificate_path : String?
      if explicit = ca_certificate_path || ENV["MINKNOW_TRUSTED_CA"]?
        raise InvalidCAPath.new("MINKNOW_TRUSTED_CA is not a certificate file path: #{explicit.inspect}") unless File.file?(explicit)
        return explicit
      end

      return unless {"localhost", "127.0.0.1", "::1", "[::1]"}.includes?(host.downcase)
      return if {"0", "false", "no"}.includes?(ENV["MINKNOW_AUTO_DETECT_CA"]?.try(&.downcase))
      default_ca_certificate_paths.find { |path| File.file?(path) }
    end
  end
end
