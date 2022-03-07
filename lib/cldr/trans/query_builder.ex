if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Cldr.Trans.QueryBuilder do
    @moduledoc """
    Provides helpers for filtering translations in `Ecto.Queries`.

    This module requires `Ecto.SQL` to be available during the compilation.
    """

    alias Cldr.LanguageTag
    require Cldr.Locale

    @doc """
    Generates a SQL fragment for accessing a translated field in an `Ecto.Query`.

    The generated SQL fragment can be coupled with the rest of the functions and operators provided
    by `Ecto.Query` and `Ecto.Query.API`.

    ## Safety

    This macro will emit errors when used with untranslatable schema modules or fields. Errors are
    emited during the compilation phase thus avoiding runtime errors after the queries are built.

    ## Examples

    Assuming the Article schema defined in
    [Structured translations](Cldr.Trans.html#module-structured-translations):

        # Return all articles that have a Spanish translation
        from a in Article, where: not is_nil(translated(Article, a, :es)))
        #=> SELECT a0."id", a0."title", a0."body", a0."translations"
        #=> FROM "articles" AS a0
        #=> WHERE (NOT (NULLIF((a0."translations"->'es'),'null') IS NULL))

        # Query items with a certain translated value
        from a in Article, where: translated(Article, a.title, :fr) == "Elixir"
        #=> SELECT a0."id", a0."title", a0."body", a0."translations"
        #=> FROM "articles" AS a0
        #=> WHERE (COALESCE(a0."translations"->$1->>$2, a0."title") = 'Elixir')

        # Query items with a translated value in the current locale
        from a in Article, where: translated(Article, a.title) == "Elixir")
        #=> SELECT a0."id", a0."title", a0."body", a0."translations"
        #=> FROM "articles" AS a0
        #=> WHERE (translate_field(a0, $1::varchar, $2::varchar, $3::varchar, $4::varchar[]) = 'Elixir')
        # Here the parameters are the following when the current locale is "en":
        #  ["translations", "title", "en", ["en-001", "en"]]

        # Query items using a case insensitive comparison
        from a in Article, where: ilike(translated(Article, a.body, :es), "%elixir%")
        #=> SELECT a0."id", a0."title", a0."body", a0."translations"
        #=> FROM "articles" AS a0
        #=> WHERE (COALESCE(a0."translations"->$1->>$2, a0."body") ILIKE '%elixir%')

    ## Structured translations vs free-form translations

    The `Cldr.Trans.QueryBuilder` works with both
    [Structured translations](Trans.html#module-structured-translations)
    and with [Free-form translations](Transl.html#module-free-form-translations).

    In most situations, the queries can be performed in the same way for both cases. **When querying
    for data translated into a certain locale we must know wheter we are using structured or
    free-form translations**.

    When using structured translations, the translations are saved as an embedded schema. This means
    that **the locale keys will be always present even if there is no translation for that locale.**
    In the database we have a `NULL` value (`nil` in Elixir).

        # If MyApp.Article uses structured translations
        from a in Cldr.Trans.Article, where: not is_nil(translated(Cldr.Trans.Article, a, :es)))
        #=> SELECT a0."id", a0."title", a0."body", a0."translations"
        #=> FROM "articles" AS a0
        #=> WHERE (NOT (NULLIF((a0."translations"->'es'),'null') IS NULL))

    ## More complex queries

    The `translated/3` macro can also be used with relations and joined schemas.
    For more complex examples take a look at the QueryBuilder tests (the file
    is located in `test/trans/query_builder_test.ex`).

    """

    defmacro translated(module, translatable, locale) do
      static_locales? = static_locales?(locale)

      with field <- field(translatable) do
        module = Macro.expand(module, __CALLER__)
        validate_field(module, field)
        generate_query(schema(translatable), module, field, locale, static_locales?)
      end
    end

    defmacro translated(module, translatable) do
      with field <- field(translatable) do
        module = Macro.expand(module, __CALLER__)
        validate_field(module, field)
        locale = quote do: Cldr.get_locale()
        generate_query(schema(translatable), module, field, locale, false)
      end
    end

    @doc """
    Generates a SQL fragment for accessing a translated field in an `Ecto.Query`
    `select` clause and returning it aliased to the original field name.

    Therefore, this macro returns a translated field with the name of the
    table's base column name which means Ecto can load it into a struct
    without further processing or conversion.

    This macro delegates to the macro `translated/3` and wraps the result in a
    fragment with the column alias.

    See `Cldr.Trans.QueryBuilder.translated/3` for more information.

    """

    defmacro translated_as(module, translatable, locale) do
      field = field(translatable)
      translated = quote do: translated(unquote(module), unquote(translatable), unquote(locale))
      do_translated_as(translated, field)
    end

    defmacro translated_as(module, translatable) do
      field = field(translatable)
      locale = quote do: Cldr.get_locale()
      translated = quote do: translated(unquote(module), unquote(translatable), unquote(locale))
      do_translated_as(translated, field)
    end

    defp do_translated_as(translated, nil) do
      translated
    end

    defp do_translated_as(translated, field) do
      {:fragment, [], ["? AS #{inspect(to_string(field))}", translated]}
    end

    defp generate_query(schema, module, field, locales, true = static_locales?) when is_list(locales) do
      for locale <- locales do
        generate_query(schema, module, field, locale, static_locales?)
      end
      |> coalesce(locales)
    end

    defp generate_query(schema, module, nil, locale, true = _static_locales?) do
      quote do
        fragment(
          "NULLIF((?->?),'null')",
          field(unquote(schema), unquote(module.__trans__(:container))),
          unquote(to_string(locale))
        )
      end
    end

    defp generate_query(schema, module, field, locale, true = _static_locales?) when Cldr.Locale.is_locale_name(locale) do
      if locale == module.__trans__(:default_locale) do
        quote do
          field(unquote(schema), unquote(field))
        end
      else
        quote do
          fragment(
            "COALESCE(?->?->>?, ?)",
            field(unquote(schema), unquote(module.__trans__(:container))),
            ^to_string(unquote(locale)),
            ^to_string(unquote(field)),
            field(unquote(schema), unquote(field))
          )
        end
      end
    end

    # Called at runtime - we use a database function
    defp generate_query(schema, module, field, locales, false = _static_locales?) do
      default_locale = to_string(module.__trans__(:default_locale) || :en)
      translate_field(module, schema, field, default_locale, locales)
    end

    defp translate_field(module, schema, nil, default_locale, locales) do
      table_alias = table_alias(schema)

      funcall =
        "translate_field(#{table_alias}, ?::varchar, ?::varchar, ?::varchar[])"

      quote do
        fragment(
          unquote(funcall),
          ^to_string(unquote(module.__trans__(:container))),
          ^to_string(unquote(default_locale)),
          ^Cldr.Trans.QueryBuilder.list_to_sql_array(unquote(locales))
        )
      end
    end

    defp translate_field(module, schema, field, default_locale, locales) do
      table_alias = table_alias(schema)

      funcall =
        "translate_field(#{table_alias}, ?::varchar, ?::varchar, ?::varchar, ?::varchar[])"

      quote do
        fragment(
          unquote(funcall),
          ^to_string(unquote(module.__trans__(:container))),
          ^to_string(unquote(field)),
          ^to_string(unquote(default_locale)),
          ^Cldr.Trans.QueryBuilder.list_to_sql_array(unquote(locales))
        )
      end
    end

    @doc false
    def list_to_sql_array(%LanguageTag{} = locale) do
      locale
      |> Cldr.Locale.fallback_locale_names!()
      |> Enum.map(&to_string/1)
    end

    def list_to_sql_array(locales) do
      locales
      |> List.wrap()
      |> Enum.map(&to_string/1)
    end

    defp coalesce(ast, enum) do
      fun = "COALESCE(" <> fragment_placeholders(enum) <> ")"

      quote do
        fragment(unquote(fun), unquote_splicing(ast))
      end
    end

    defp fragment_placeholders(enum) do
      enum
      |> Enum.map(fn _x -> "?" end)
      |> Enum.join(",")
    end

    # Heuristic to guess the Ecto table alias name based upon
    # the binding.  If the binding ends in a digit then we assume
    # this is actually the table alias.  If it is not, append a `0`
    # and treat it as the table alias.  This because its not
    # possible to know the table alias at compile time.
    @digits Enum.map(0..9, &to_string/1)

    defp table_alias({schema, _, _}) do
      schema = to_string(schema)
      if String.ends_with?(schema, @digits), do: schema, else: schema <> "0"
    end

    defp schema({{:., _, [schema, _field]}, _metadata, _args}), do: schema
    defp schema(schema), do: schema

    defp field({{:., _, [_schema, field]}, _metadata, _args}), do: field
    defp field(_), do: nil

    defp validate_field(module, field) do
      cond do
        is_nil(field) ->
          nil

        not Cldr.Trans.translatable?(module, field) ->
          raise ArgumentError,
            message: "'#{inspect(module)}' module must declare '#{field}' as translatable"

        true ->
          nil
      end
    end

    require Cldr

    defp static_locales?(locale) when is_atom(locale), do: true
    defp static_locales?(locale) when is_binary(locale), do: true
    defp static_locales?(locales) when is_list(locales),
      do: Enum.all?(locales, &Cldr.is_locale_name/1)

    defp static_locales?(_locales), do: false
  end
end
