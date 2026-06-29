require "sorbet-runtime"
require "tty-exit"
require "fileutils"

require_relative "../../common_opts"

module UdbGen
  class GenSingleIdlOptions < SubcommandWithCommonOptions
    include TTY::Exit

    NAME = "single-idl"

    sig { void }
    def initialize
      super(name: NAME,
            desc: "Emit one self-contained, config-pruned IDL (.isa) file for a config")
    end

    usage \
      command: NAME,
      desc: "Emit a single self-contained .isa with only the config-reachable IDL " \
            "(globals, enums, bitfields, structs, functions, fetch)",
      example: <<~EXAMPLE
        Emit for the rv64 config to stdout
          $ #{File.basename($PROGRAM_NAME)} #{NAME} -c rv64
        Emit for a custom config file to a path
          $ #{File.basename($PROGRAM_NAME)} #{NAME} -c /path/to/cfg.yaml -o out.isa
      EXAMPLE

    option :output do
      T.bind(self, TTY::Option::Parameter::Option)
      short "-o"
      long "--output=file"
      desc "Output .isa path (default: stdout)"
      convert :path
    end

    sig { override.params(argv: T::Array[String]).returns(T.noreturn) }
    def run(argv)
      parse(argv)

      if params[:help]
        Kernel.print help
        exit_with(:success)
      end
      exit_with(:usage_error, "#{params.errors.summary}\n\n#{help}") if params.errors.any?
      exit_with(:usage_error, "Unknown arguments: #{params.remaining}\n") unless params.remaining.empty?

      isa = emit

      if params[:output].nil?
        $stdout.write(isa)
      else
        FileUtils.mkdir_p(params[:output].dirname)
        File.write(params[:output], isa)
        Udb.logger.info "Generated single IDL: #{params[:output]}"
      end
      exit_with(:success)
    end

    private

    # Stub: header only. Filled in Task 3.
    sig { returns(String) }
    def emit
      "%version: 1.0\n"
    end
  end
end
