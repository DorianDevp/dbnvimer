local t = require("tests.init")
local detect = require("dbclient.connections.detect")

t.describe("connection URL parsing", {
  ["parses a postgres URL"] = function()
    local spec = detect.parse_url("postgres://app:secret@db.example.com:5433/shop")
    t.eq(spec.adapter, "postgres")
    t.eq(spec.host, "db.example.com")
    t.eq(spec.port, 5433)
    t.eq(spec.user, "app")
    t.eq(spec.password, "secret")
    t.eq(spec.database, "shop")
  end,

  ["defaults the port"] = function()
    t.eq(detect.parse_url("postgresql://app@localhost/shop").port, 5432)
    t.eq(detect.parse_url("mysql://root@localhost/shop").port, 3306)
  end,

  ["maps mysql onto the mariadb adapter"] = function()
    t.eq(detect.parse_url("mysql://root:pw@127.0.0.1:3307/app").adapter, "mariadb")
    t.eq(detect.parse_url("mysql2://root@127.0.0.1/app").adapter, "mariadb")
  end,

  ["handles a driver suffix"] = function()
    t.eq(detect.parse_url("postgres+psycopg2://app@localhost/shop").adapter, "postgres")
  end,

  ["percent-decodes credentials"] = function()
    local spec = detect.parse_url("postgres://a%40b:p%3Aw@localhost/db")
    t.eq(spec.user, "a@b")
    t.eq(spec.password, "p:w")
  end,

  ["drops a query string from the database name"] = function()
    t.eq(detect.parse_url("postgres://app@localhost/shop?sslmode=require").database, "shop")
  end,

  ["parses sqlite paths"] = function()
    local spec = detect.parse_url("sqlite:///var/lib/app.db")
    t.eq(spec.adapter, "sqlite")
    t.eq(spec.path, "/var/lib/app.db")
  end,

  ["ignores URLs it does not understand"] = function()
    t.eq(detect.parse_url("redis://localhost:6379"), nil)
    t.eq(detect.parse_url("not a url"), nil)
    t.eq(detect.parse_url(nil), nil)
  end,
})

t.describe("yaml subset parsing", {
  ["reads nested maps"] = function()
    local document = detect.parse_yaml(vim.split(
      [[
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: shop
    ports:
      - "5433:5432"
]],
      "\n"
    ))

    t.eq(document.services.db.image, "postgres:16")
    t.eq(document.services.db.environment.POSTGRES_USER, "app")
    t.eq(document.services.db.ports[1], "5433:5432")
  end,

  ["reads list-form environments"] = function()
    local document = detect.parse_yaml(vim.split(
      [[
services:
  mysql:
    image: mariadb:11
    environment:
      - MYSQL_ROOT_PASSWORD=root
      - MYSQL_DATABASE=app
]],
      "\n"
    ))
    t.eq(document.services.mysql.environment[1], "MYSQL_ROOT_PASSWORD=root")
  end,

  ["ignores comments"] = function()
    local document = detect.parse_yaml({ "# comment", "key: value # trailing" })
    t.eq(document.key, "value")
  end,
})

t.describe("project scanning", {
  ["finds a database URL in a .env file"] = function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({
      "# comment",
      "APP_ENV=dev",
      'DATABASE_URL="postgres://app:pw@127.0.0.1:5432/shop"',
    }, dir .. "/.env")

    local found = detect.scan({ cwd = dir, sources = { "env" }, depth = 1 })
    local entry = found["env:database"]
    t.ok(entry, "expected a detected connection, got " .. vim.inspect(vim.tbl_keys(found)))
    t.eq(entry.adapter, "postgres")
    t.eq(entry.database, "shop")
    t.ok(entry.detected)
  end,

  ["reads a docker-compose service"] = function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(
      vim.split(
        [[
services:
  postgres:
    image: postgres:16-alpine
    ports:
      - "5433:5432"
    environment:
      POSTGRES_USER: shop
      POSTGRES_PASSWORD: shoppw
      POSTGRES_DB: shopdb
]],
        "\n"
      ),
      dir .. "/docker-compose.yml"
    )

    local found = detect.scan({ cwd = dir, sources = { "docker_compose" }, depth = 1 })
    local entry = found["compose:postgres"]
    t.ok(entry, "expected a compose connection, got " .. vim.inspect(vim.tbl_keys(found)))
    t.eq(entry.adapter, "postgres")
    t.eq(entry.port, 5433, "the published host port is the one to connect to")
    t.eq(entry.user, "shop")
    t.eq(entry.database, "shopdb")
  end,

  ["ignores services that are not databases"] = function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(
      vim.split("services:\n  cache:\n    image: redis:7\n", "\n"),
      dir .. "/docker-compose.yml"
    )
    local found = detect.scan({ cwd = dir, sources = { "docker_compose" }, depth = 1 })
    t.eq(vim.tbl_count(found), 0)
  end,
})
