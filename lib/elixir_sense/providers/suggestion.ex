defmodule ElixirSense.Providers.Suggestion do
  @moduledoc """
  Provider responsible for finding suggestions for auto-completing
  """

  alias ElixirSense.Core.Binding
  alias ElixirSense.Core.Introspection
  alias ElixirSense.Core.Source
  alias ElixirSense.Core.State
  alias ElixirSense.Core.TypeInfo
  alias ElixirSense.Providers.Suggestion.Complete
  alias ElixirSense.Providers.Suggestion.Hint

  @type attribute :: %{
          type: :attribute,
          name: String.t()
        }

  @type variable :: %{
          type: :variable,
          name: String.t()
        }

  @type field :: %{
          type: :field,
          subtype: :struct_field | :map_key,
          name: String.t(),
          origin: String.t() | nil,
          call?: boolean
        }

  @type return :: %{
          type: :return,
          description: String.t(),
          spec: String.t(),
          snippet: String.t()
        }

  @type callback :: %{
          type: :callback,
          name: String.t(),
          arity: non_neg_integer,
          args: String.t(),
          origin: String.t(),
          summary: String.t(),
          spec: String.t(),
          metadata: map
        }

  @type protocol_function :: %{
          type: :protocol_function,
          name: String.t(),
          arity: non_neg_integer,
          args: String.t(),
          origin: String.t(),
          summary: String.t(),
          spec: String.t(),
          metadata: map
        }

  @type func :: %{
          type: :function | :macro,
          name: String.t(),
          arity: non_neg_integer,
          args: String.t(),
          origin: String.t(),
          summary: String.t(),
          spec: String.t(),
          metadata: map
        }

  @type mod :: %{
          type: :module,
          name: String.t(),
          subtype: String.t(),
          summary: String.t(),
          metadata: map
        }

  @type param_option :: %{
          type: :param_option,
          name: String.t(),
          origin: String.t(),
          type_spec: String.t(),
          doc: String.t(),
          expanded_spec: String.t()
        }

  @type type_spec :: %{
          type: :type_spec,
          name: String.t(),
          arity: non_neg_integer,
          origin: String.t(),
          spec: String.t(),
          doc: String.t(),
          signature: String.t(),
          metadata: map
        }

  @type hint :: %{
          type: :hint,
          value: String.t()
        }

  @type suggestion ::
          attribute
          | variable
          | field
          | return
          | callback
          | protocol_function
          | func
          | mod
          | hint
          | param_option
          | type_spec

  @doc """
  Finds all suggestions for a hint based on context information.
  """
  @spec find(
          String.t(),
          State.Env.t(),
          State.structs_t(),
          State.mods_funs_to_positions_t(),
          State.types_t(),
          State.specs_t(),
          String.t()
        ) :: [suggestion]
  def find(
        hint,
        %State.Env{} = env,
        structs,
        mods_and_funs,
        metadata_types,
        metadata_specs,
        text_before
      ) do
    case find_struct_fields(
           hint,
           text_before,
           env,
           structs,
           mods_and_funs,
           metadata_specs,
           metadata_types
         ) do
      {[], _} ->
        find_all_except_struct_fields(
          hint,
          env,
          mods_and_funs,
          metadata_types,
          metadata_specs,
          structs,
          text_before
        )

      {fields, nil} ->
        Hint.get(hint, fields)

      {fields, :maybe_struct_update} ->
        mods_funcs_suggestions =
          find_hint_mods_funcs(
            hint,
            env,
            mods_and_funs,
            metadata_specs,
            metadata_types,
            structs,
            text_before
          )

        Hint.combine(mods_funcs_suggestions, fields)
    end
  end

  @spec find_all_except_struct_fields(
          String.t(),
          State.Env.t(),
          State.mods_funs_to_positions_t(),
          State.types_t(),
          State.specs_t(),
          State.structs_t(),
          String.t()
        ) :: [suggestion]
  defp find_all_except_struct_fields(
         hint,
         %State.Env{
           imports: imports,
           aliases: aliases,
           behaviours: behaviours,
           scope: scope,
           module: module,
           protocol: protocol
         } = env,
         mods_and_funs,
         metadata_types,
         metadata_specs,
         structs,
         text_before
       ) do
    mods_and_funcs =
      find_hint_mods_funcs(
        hint,
        env,
        mods_and_funs,
        metadata_specs,
        metadata_types,
        structs,
        text_before
      )

    callbacks_or_returns =
      case scope do
        {_f, _a} ->
          find_returns(behaviours, protocol, metadata_specs, hint, module, scope)

        _mod ->
          find_callbacks(behaviours, protocol, hint) ++ find_protocol_functions(protocol, hint)
      end

    param_options =
      find_param_options(
        text_before,
        hint,
        imports,
        aliases,
        module,
        mods_and_funs,
        metadata_types
      )

    typespecs = find_typespecs(hint, aliases, module, scope, mods_and_funs, metadata_types)

    Hint.combine(mods_and_funcs, param_options ++ typespecs ++ callbacks_or_returns)
  end

  @spec find_struct_fields(
          String.t(),
          String.t(),
          State.Env.t(),
          State.structs_t(),
          State.mods_funs_to_positions_t(),
          State.specs_t(),
          State.types_t()
        ) :: {[suggestion], nil | :maybe_struct_update}
  defp find_struct_fields(
         hint,
         text_before,
         %State.Env{
           module: module,
           vars: vars,
           attributes: attributes,
           aliases: aliases,
           imports: imports
         },
         structs,
         mods_funs,
         specs,
         metadata_types
       ) do
    env = %ElixirSense.Core.Binding{
      attributes: attributes,
      variables: vars,
      structs: structs,
      imports: imports,
      current_module: module,
      specs: specs,
      types: metadata_types,
      mods_and_funs: mods_funs
    }

    case Source.which_struct(text_before, module) do
      {type, fields_so_far, elixir_prefix, var} ->
        type =
          case {type, elixir_prefix} do
            {{:atom, mod}, false} ->
              # which_struct returns not expamded aliases
              {:atom, Introspection.expand_alias(mod, aliases)}

            _ ->
              type
          end

        type = Binding.expand(env, {:struct, [], type, var})

        result = get_fields(type, hint, fields_so_far)
        {result, if(fields_so_far == [], do: :maybe_struct_update)}

      {:map, fields_so_far, var} ->
        var = Binding.expand(env, var)

        result = get_fields(var, hint, fields_so_far)
        {result, if(fields_so_far == [], do: :maybe_struct_update)}

      _ ->
        {[], nil}
    end
  end

  defp get_fields({:map, fields, _}, hint, fields_so_far) do
    expand_map_field_access(fields, hint, :map, fields_so_far)
  end

  defp get_fields({:struct, fields, type, _}, hint, fields_so_far) do
    expand_map_field_access(fields, hint, {:struct, type}, fields_so_far)
  end

  defp get_fields(_, _hint, _fields_so_far), do: []

  defp expand_map_field_access(fields, hint, type, fields_so_far) do
    for {key, _value} when is_atom(key) <- fields,
        key not in fields_so_far,
        key = Atom.to_string(key),
        String.starts_with?(key, hint) do
      {subtype, origin} =
        case type do
          {:struct, mod} -> {:struct_field, if(mod, do: inspect(mod))}
          :map -> {:map_key, nil}
        end

      %{type: :field, name: key, subtype: subtype, origin: origin, call?: false}
    end
    |> Enum.sort_by(& &1.name)
  end

  @spec find_hint_mods_funcs(
          String.t(),
          State.Env.t(),
          State.mods_funs_to_positions_t(),
          State.specs_t(),
          State.types_t(),
          State.structs_t(),
          String.t()
        ) ::
          %{
            hint: hint,
            suggestions: [mod | func | field | variable | attribute]
          }
  defp find_hint_mods_funcs(
         hint,
         %State.Env{
           imports: imports,
           aliases: aliases,
           module: module,
           vars: vars,
           attributes: attributes,
           scope: scope
         },
         mods_and_funs,
         metadata_specs,
         metadata_types,
         structs,
         text_before
       ) do
    env = %Complete.Env{
      aliases: aliases,
      vars: vars,
      attributes: attributes,
      scope_module: module,
      imports: imports,
      mods_and_funs: mods_and_funs,
      specs: metadata_specs,
      structs: structs,
      types: metadata_types,
      scope: scope
    }

    {hint, prefix} =
      case Source.get_v12_module_prefix(text_before, module) do
        nil ->
          {hint, ""}

        module_string ->
          # v1.2 alias syntax detected
          # prepend module prefix before running completion
          prefix = module_string <> "."
          {prefix <> hint, prefix}
      end

    {hint, module_special_form_replaced} =
      if String.starts_with?(hint, "__MODULE__") do
        {hint |> String.replace_leading("__MODULE__", inspect(module)), true}
      else
        {hint, false}
      end

    {%{type: :hint, value: prefixed_value}, suggestions} = Complete.complete(hint, env)

    prefixed_value =
      if module_special_form_replaced do
        prefixed_value |> String.replace_leading(inspect(module), "__MODULE__")
      else
        prefixed_value
      end

    # drop module prefix from hint if added
    value =
      if prefix != "" do
        prefixed_value |> String.replace_leading(prefix, "")
      else
        prefixed_value
      end

    %{hint: %{type: :hint, value: value}, suggestions: suggestions}
  end

  @spec find_returns(
          [module],
          nil | State.protocol_t(),
          State.specs_t(),
          String.t(),
          module | nil,
          State.scope()
        ) :: [return]
  defp find_returns(behaviours, protocol, specs, "", current_module, {fun, arity}) do
    spec_returns =
      case specs[{current_module, fun, arity}] do
        nil ->
          []

        %State.SpecInfo{specs: info_specs} ->
          for spec <- info_specs,
              {:ok, {:@, _, [{_, _, [quoted]}]}} = Code.string_to_quoted(spec),
              return <- Introspection.get_returns_from_spec_ast(quoted) do
            format_return(return)
          end
      end

    callbacks =
      for mod <- behaviours,
          protocol == nil or mod != elem(protocol, 0),
          Introspection.define_callback?(mod, fun, arity),
          return <- Introspection.get_returns_from_callback(mod, fun, arity) do
        format_return(return)
      end

    protocol_functions =
      case protocol do
        {proto, _implementations} ->
          if Introspection.define_callback?(proto, fun, arity) do
            for return <- Introspection.get_returns_from_callback(proto, fun, arity) do
              format_return(return)
            end
          else
            []
          end

        nil ->
          []
      end

    callbacks ++ protocol_functions ++ spec_returns
  end

  defp find_returns(_behaviours, _protocol, _specs, _hint, _current_module, _scope) do
    []
  end

  defp format_return(return) do
    %{
      type: :return,
      description: return.description,
      spec: return.spec,
      snippet: return.snippet
    }
  end

  @spec find_callbacks([module], nil | State.protocol_t(), String.t()) :: [callback]
  defp find_callbacks(behaviours, protocol, hint) do
    behaviours
    |> Enum.flat_map(fn
      mod when is_atom(mod) and (protocol == nil or mod != elem(protocol, 0)) ->
        mod_name = inspect(mod)

        for %{
              name: name,
              arity: arity,
              callback: spec,
              signature: signature,
              doc: doc,
              metadata: metadata
            } <-
              Introspection.get_callbacks_with_docs(mod),
            hint == "" or String.starts_with?("#{name}", hint) do
          desc = Introspection.extract_summary_from_docs(doc)
          [_, args_str] = Regex.run(Regex.recompile!(~r/.\((.*)\)/), signature)
          args = args_str |> String.replace(Regex.recompile!(~r/\s/), "")

          %{
            type: :callback,
            name: Atom.to_string(name),
            arity: arity,
            args: args,
            origin: mod_name,
            summary: desc,
            spec: spec,
            metadata: metadata
          }
        end

      _ ->
        []
    end)
    |> Enum.sort()
  end

  @spec find_protocol_functions(nil | State.protocol_t(), String.t()) :: [protocol_function]
  defp find_protocol_functions(nil, _hint), do: []

  defp find_protocol_functions({protocol, _implementations}, hint) do
    for {{name, arity}, {_type, args, docs, metadata, spec}} <-
          Introspection.module_functions_info(protocol),
        hint == "" or String.starts_with?("#{name}", hint) do
      %{
        type: :protocol_function,
        name: Atom.to_string(name),
        arity: arity,
        args: args,
        origin: inspect(protocol),
        summary: docs,
        metadata: metadata,
        spec: spec
      }
    end
    |> Enum.sort()
  end

  @spec find_param_options(
          String.t(),
          String.t(),
          [module],
          [{module, module}],
          module,
          State.mods_funs_to_positions_t(),
          State.types_t()
        ) ::
          [
            param_option
          ]
  defp find_param_options(prefix, hint, imports, aliases, module, mods_funs, metadata_types) do
    with %{
           candidate: {mod, fun},
           elixir_prefix: elixir_prefix,
           npar: npar,
           pipe_before: _pipe_before
         } <-
           Source.which_func(prefix, module),
         {mod, fun, true} <-
           Introspection.actual_mod_fun(
             {mod, fun},
             imports,
             if(elixir_prefix, do: [], else: aliases),
             module,
             mods_funs,
             metadata_types
           ) do
      TypeInfo.extract_param_options(mod, fun, npar)
      |> options_to_suggestions(mod)
      |> Enum.filter(&String.starts_with?(&1.name, hint))
    else
      _ ->
        []
    end
  end

  defp options_to_suggestions(options, original_module) do
    Enum.map(options, fn
      {mod, name, type} ->
        TypeInfo.get_type_info(mod, type, original_module)
        |> Map.merge(%{type: :param_option, name: name |> Atom.to_string()})

      {mod, name} ->
        %{
          doc: "",
          expanded_spec: "",
          name: name |> Atom.to_string(),
          origin: inspect(mod),
          type: :param_option,
          type_spec: ""
        }
    end)
  end

  @spec find_typespecs(
          String.t(),
          [{module, module}],
          module,
          State.scope(),
          State.mods_funs_to_positions_t(),
          State.types_t()
        ) ::
          [
            type_spec
          ]

  # We don't list typespecs when inside a function
  defp find_typespecs(_hint, _aliases, _module, {_m, _f}, _, _) do
    []
  end

  # We don't list typespecs outside of a module
  defp find_typespecs(_hint, _aliases, _module, scope, _, _) when scope in [Elixir, nil] do
    []
  end

  # We don't list typespecs when the hint is most likely an attribute
  defp find_typespecs("@" <> _, _aliases, _module, _scope, _, _) do
    []
  end

  defp find_typespecs(hint, aliases, module, _scope, mods_and_funs, metadata_types) do
    {mod, hint} =
      hint
      |> Source.split_module_and_hint(module, aliases)

    find_typespecs_for_mod_and_hint({mod, hint}, aliases, module, mods_and_funs, metadata_types)
    |> Kernel.++(find_builtin_types({mod, hint}))
  end

  defp find_typespecs_for_mod_and_hint(
         {mod, hint},
         aliases,
         module,
         mods_and_funs,
         metadata_types
       ) do
    case Introspection.actual_module(mod, aliases, module, mods_and_funs) do
      {actual_mod, true} ->
        find_module_types(actual_mod, {mod, hint}, metadata_types, module)

      {nil, false} ->
        find_module_types(module, {mod, hint}, metadata_types, module)

      {_, false} ->
        []
    end
  end

  defp find_builtin_types({nil, hint}) do
    TypeInfo.find_all_builtin(&String.starts_with?("#{&1.name}", hint))
    |> Enum.map(&type_info_to_suggestion(&1, nil))
  end

  defp find_builtin_types({_mod, _hint}), do: []

  defp find_module_types(actual_mod, {mod, hint}, metadata_types, module) do
    find_metadata_types(actual_mod, {mod, hint}, metadata_types, module)
    |> Kernel.++(TypeInfo.find_all(actual_mod, &String.starts_with?("#{&1.name}", hint)))
    |> Enum.map(&type_info_to_suggestion(&1, actual_mod))
  end

  defp find_metadata_types(actual_mod, {mod, hint}, metadata_types, module) do
    include_private = mod == nil and actual_mod == module

    for {{mod, type, arity}, type_info} when is_integer(arity) <- metadata_types,
        mod == actual_mod,
        type |> Atom.to_string() |> String.starts_with?(hint),
        include_private or type_info.kind != :typep,
        do: type_info
  end

  defp type_info_to_suggestion(type_info, module) do
    origin = if module, do: inspect(module), else: ""

    case type_info do
      %ElixirSense.Core.State.TypeInfo{args: [args]} ->
        args_stringified = Enum.join(args, ", ")

        %{
          type: :type_spec,
          name: type_info.name |> Atom.to_string(),
          arity: length(args),
          signature: "#{type_info.name}(#{args_stringified})",
          origin: origin,
          doc: "",
          spec: "",
          # TODO extract doc and meta
          metadata: %{}
        }

      _ ->
        %{
          type: :type_spec,
          name: type_info.name |> Atom.to_string(),
          arity: type_info.arity,
          signature: type_info.signature,
          origin: origin,
          doc: type_info.doc,
          spec: type_info.spec,
          metadata: type_info.metadata
        }
    end
  end
end
