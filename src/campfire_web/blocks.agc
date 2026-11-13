import Bond from "pkg/bond/bond"

## Gives a `do` block the type of a handler, so that a name can hold it before the pipeline of routes that uses it: a
## chain after the `end` of a block (`do ... end |> Bond.get(...)`) is refused by the next Agentica.
def handler(f: Bond.Handler) -> Bond.Handler = f
