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

    sig { returns(String) }
    def emit
      # Dead-branch pruning is an upstream resolved-arch pass; the generator only serializes.
      ast = cfg_arch.pruned_global_ast
      # Function-reachability pruning is the existing resolved-arch dimension.
      reachable = cfg_arch.reachable_functions(show_progress: false).map(&:name).to_set

      parts = ["%version: 1.0", ""]
      emit_each(parts, ast.globals)
      emit_each(parts, ast.enums)
      emit_each(parts, ast.bitfields)
      emit_each(parts, ast.structs)
      # Intersection of the two pruning dimensions: dead-branch-pruned bodies, reachable only.
      emit_each(parts, ast.functions.select { |f| reachable.include?(f.name) })
      # fetch is already-IDL too; emit it when present (skip the raising IsaAst#fetch accessor).
      emit_each(parts, ast.definitions.grep(Idl::FetchAst))
      parts.join("\n") + "\n"
    end

    sig { params(parts: T::Array[String], nodes: T::Array[T.untyped]).void }
    def emit_each(parts, nodes)
      nodes.each do |n|
        parts << n.to_idl
        parts << ""
      end
    end
  end
end
