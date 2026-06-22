require "sqlite3"

# Open an in-memory database to verify the sqlite3 binding works
DB.open("sqlite3::memory:") do |db|
  db.exec "CREATE TABLE test (id INTEGER PRIMARY KEY, val TEXT)"
  db.exec "INSERT INTO test (val) VALUES (?)", "hello from crystal-build-tools sqlite test"
  val = db.scalar("SELECT val FROM test LIMIT 1").as(String)
  puts val
end

exit 0
