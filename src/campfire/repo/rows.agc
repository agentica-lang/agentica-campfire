## Reading a column of a row of agentica-db, for the modules that run SQL.

import Db from "pkg/db/db"

## The text of `column`, or "" when the row has no such column or it holds something else.
def text_of(row: Db.Row, column: String) -> String
  case row.get(column, Db.Value.Null)
    Db.Value.Text(text) -> text
    # Every other variant (and a missing column) is "no text", also one that `Db.Value` gets later: the columns that
    # these read are `text` in the schema, so anything else is a row that did not come from it.
    _ -> ""
  end
end

## The whole number in `column`, or -1 when it has none, which no id or count is, so a caller never takes it for a row.
def int_of(row: Db.Row, column: String) -> Int
  case row.get(column, Db.Value.Null)
    Db.Value.Int(number) -> number
    _ -> -1
  end
end
