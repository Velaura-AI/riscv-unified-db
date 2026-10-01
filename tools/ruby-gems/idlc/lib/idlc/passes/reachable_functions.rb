# typed: false
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# frozen_string_literal: true

# finds all reachable functions from a give sequence of statements

module Idl
  class AstNode
    ReachableFunctionCacheType = T.type_alias { T::Hash[T::Array[T.untyped], T::Array[FunctionDefAst]] }

    # Names of the variables that may be assigned anywhere in this subtree (nested control flow
    # included). Used to decide which values stop being known after code that may not run.
    sig { params(acc: T::Set[String]).returns(T::Set[String]) }
    def assigned_variable_names(acc = T::Set[String].new)
      case self
      when VariableAssignmentAst
        acc << lhs.text_value unless lhs.is_a?(CsrWriteAst)
      when AryElementAssignmentAst
        base = AstNode.extract_base_var_name(lhs)
        acc << base unless base.nil?
      when AryRangeAssignmentAst
        base = AstNode.extract_base_var_name(variable)
        acc << base unless base.nil?
      when FieldAssignmentAst
        acc << id.name
      when PostIncrementExpressionAst, PostDecrementExpressionAst
        acc << rval.text_value if rval.is_a?(IdAst)
      end
      children.each { |child| child.assigned_variable_names(acc) }
      acc
    end

    # Make every variable this subtree may assign unknown in `symtab`.
    #
    # The pass executes assignments as it walks so that later conditions can be folded. That is only
    # sound where the assignment is certain to run. For code that may NOT run (an arm taken under an
    # unknown condition, a loop body, a conditional statement), a variable assigned there is NOT
    # known afterwards, and a sibling arm must not see it. Without this the pass kept whatever value
    # the last walked arm left, so `if (unknown) { x = 0; } f(x);` analysed f with x == 0, folded a
    # condition inside f, and dropped the callee under it (fcvt.d.s lost the subnormal path of
    # f32_to_f64_no_flag this way).
    sig { params(symtab: SymbolTable).void }
    def forget_assigned_variables(symtab)
      assigned_variable_names.each do |name|
        var = symtab.get(name)
        next unless var.is_a?(Var)
        next if var.type.global?

        var.value = nil
      end
    end

    # @return [Array<FunctionDefAst>] List of all functions that can be reached (via function calls) from this node
    sig {
      params(symtab: SymbolTable, cache: ReachableFunctionCacheType )
      .returns(T::Array[FunctionDefAst])
    }
    def reachable_functions(symtab, cache = T.let({}, ReachableFunctionCacheType))
      seen = {}
      children.each_with_object([]) do |child, result|
        child.reachable_functions(symtab, cache).each do |fn|
          unless seen.key?(fn.name)
            seen[fn.name] = true
            result << fn
          end
        end
      end
    end
  end

  class FunctionCallExpressionAst
    sig {
      params(symtab: SymbolTable, cache: ReachableFunctionCacheType )
      .returns(T::Array[FunctionDefAst])
    }
    def reachable_functions(symtab, cache = T.let({}, ReachableFunctionCacheType))
      func_def_type = func_type(symtab)

      body_symtab = symtab.global_clone
      body_symtab.push(func_def_type.func_def_ast)

      # Use a hash keyed by name to accumulate unique functions without repeated uniq scans
      fns_by_name = {}

      begin
        arg_nodes.each do |a|
          a.reachable_functions(symtab, cache).each { |fn| fns_by_name[fn.name] ||= fn }
        end

        unless func_def_type.builtin? || func_def_type.generated?
          avals = func_def_type.apply_arguments(body_symtab, arg_nodes, symtab, self)

          idx = [name, avals].hash

          if cache.key?(idx)
            # Use cached results from a prior traversal (e.g., same function called
            # by an earlier instruction). The sentinel [] handles recursion cycles.
            cache[idx].each { |fn| fns_by_name[fn.name] ||= fn }
          else
            cache[idx] = [] # sentinel: breaks recursion cycles before body is traversed
            body_fns = func_def_type.body.reachable_functions(body_symtab, cache)
            cache[idx] = body_fns
            body_fns.each { |fn| fns_by_name[fn.name] ||= fn }
          end
        end

        fns_by_name[func_def_type.func_def_ast.name] ||= func_def_type.func_def_ast
      ensure
        body_symtab.pop
        body_symtab.release
      end

      fns_by_name.values
    end
  end

  class StatementAst
    sig {
      params(symtab: SymbolTable, cache: ReachableFunctionCacheType )
      .returns(T::Array[FunctionDefAst])
    }
    def reachable_functions(symtab, cache = T.let({}, ReachableFunctionCacheType))
      fns = action.reachable_functions(symtab, cache)

      action.add_symbol(symtab) if action.declaration?
      value_try do
        action.execute(symtab) if action.executable?
      rescue SystemStackError
        type_error "Detected unbounded recursion during compile-time constant evaluation at #{input_file}:#{input_line}.. This recursion cannot be represented or validated."
      end
      # ok

      fns
    end
  end


  class IfAst
    sig {
      params(symtab: SymbolTable, cache: ReachableFunctionCacheType )
      .returns(T::Array[FunctionDefAst])
    }
    def reachable_functions(symtab, cache = T.let({}, ReachableFunctionCacheType))
      # Set once the walk reaches an arm whose condition is not known at compile time. From then on
      # we cannot say which arm runs, so no variable assigned in any arm has a known value after the
      # if (see AstNode#forget_assigned_variables).
      uncertain = T.let([false], T::Array[T::Boolean])
      fns = reachable_functions_walk(symtab, cache, uncertain)
      forget_assigned_variables(symtab) if uncertain.fetch(0)
      fns
    end

    sig {
      params(symtab: SymbolTable, cache: ReachableFunctionCacheType, uncertain: T::Array[T::Boolean])
      .returns(T::Array[FunctionDefAst])
    }
    def reachable_functions_walk(symtab, cache, uncertain)
      fns = []
      value_try do
        fns.concat if_cond.reachable_functions(symtab, cache)
        value_result = value_try do
          if (if_cond.value(symtab))
            fns.concat if_body.reachable_functions(symtab, cache)
            return fns # no need to continue
          else
            if (if_cond.text_value == "pending_and_enabled_interrupts != 0")
              warn symtab.get("pending_and_enabled_interrupts")
              raise "???"
            end
            elseifs.each do |eif|
              fns.concat eif.cond.reachable_functions(symtab, cache)
              value_result = value_try do
                if (eif.cond.value(symtab))
                  fns.concat eif.body.reachable_functions(symtab, cache)
                  return fns # no need to keep going
                end
              end
              value_else(value_result) do
                # condition isn't known; body is potentially reachable, and so are the arms after it
                uncertain[0] = true
                forget_assigned_variables(symtab)
                fns.concat eif.body.reachable_functions(symtab, cache)
              end
            end
            forget_assigned_variables(symtab) if uncertain.fetch(0)
            fns.concat final_else_body.reachable_functions(symtab, cache)
          end
        end
        value_else(value_result) do
          # condition isn't known: any arm may run, and values must not pass between arms
          uncertain[0] = true
          forget_assigned_variables(symtab)
          fns.concat if_body.reachable_functions(symtab, cache)

          elseifs.each do |eif|
            fns.concat eif.cond.reachable_functions(symtab, cache)
            value_result = value_try do
              if (eif.cond.value(symtab))
                forget_assigned_variables(symtab)
                fns.concat eif.body.reachable_functions(symtab, cache)
                return fns # no need to keep going
              end
            end
            value_else(value_result) do
              # condition isn't known; body is potentially reachable
              forget_assigned_variables(symtab)
              fns.concat eif.body.reachable_functions(symtab, cache)
            end
          end
          forget_assigned_variables(symtab)
          fns.concat final_else_body.reachable_functions(symtab, cache)
        end
      end
      return fns
    end
  end

  class ConditionalReturnStatementAst
    sig {
      params(symtab: SymbolTable, cache: ReachableFunctionCacheType )
      .returns(T::Array[FunctionDefAst])
    }
    def reachable_functions(symtab, cache = T.let({}, ReachableFunctionCacheType))
      fns = condition.is_a?(FunctionCallExpressionAst) ? condition.reachable_functions(symtab, cache) : []
      value_result = value_try do
        cv = condition.value(symtab)
        if cv
          fns.concat return_expression.reachable_functions(symtab, cache)
        end
      end
      value_else(value_result) do
        fns.concat return_expression.reachable_functions(symtab, cache)
      end

      fns
    end
  end

  class ConditionalStatementAst
    sig {
      params(symtab: SymbolTable, cache: ReachableFunctionCacheType )
      .returns(T::Array[FunctionDefAst])
    }
    def reachable_functions(symtab, cache = T.let({}, ReachableFunctionCacheType))

      fns = condition.is_a?(FunctionCallExpressionAst) ? condition.reachable_functions(symtab, cache) : []

      may_run = false
      value_result = value_try do
        if condition.value(symtab)
          may_run = true
          fns.concat action.reachable_functions(symtab, cache)
          # the action is not executed here, so any variable it assigns is no longer known below
        end
      end
      value_else(value_result) do
        # condition not known
        may_run = true
        fns = fns.concat action.reachable_functions(symtab, cache)
      end
      action.forget_assigned_variables(symtab) if may_run

      fns
    end
  end

  class ForLoopAst
    sig {
      params(symtab: SymbolTable, cache: ReachableFunctionCacheType )
      .returns(T::Array[FunctionDefAst])
    }
    def reachable_functions(symtab, cache = T.let({}, ReachableFunctionCacheType))
      symtab.push(self)
      begin
        symtab.add(init.lhs.name, Var.new(init.lhs.name, init.lhs_type(symtab)))
        fns = init.is_a?(FunctionCallExpressionAst) ? init.reachable_functions(symtab, cache) : []
        fns.concat(condition.reachable_functions(symtab, cache))
        fns.concat(update.reachable_functions(symtab, cache))
        # The body runs an unknown number of times, and a value assigned late in it is visible to
        # the earlier statements of the next iteration, so nothing assigned in it is known on entry
        # or on exit.
        stmts.each { |stmt| stmt.forget_assigned_variables(symtab) }
        stmts.each do |stmt|
          fns.concat(stmt.reachable_functions(symtab, cache))
        end
      ensure
        symtab.pop
      end
      stmts.each { |stmt| stmt.forget_assigned_variables(symtab) }
      fns
    end
  end
end
