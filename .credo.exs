%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          # Consistency checks
          {Credo.Check.Consistency.ExceptionNames, false},

          # Readability checks - allow explicit try for clarity in detector code
          {Credo.Check.Readability.PreferImplicitTry, false},

          # Refactoring - allow slightly higher complexity for platform detection
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 15]},
          {Credo.Check.Refactor.Nesting, [max_nesting: 4]}
        ]
      }
    }
  ]
}
