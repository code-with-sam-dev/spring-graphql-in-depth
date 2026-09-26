# GraphQL with Spring Boot, in depth

One shop, served twice: a REST controller and a GraphQL controller over the same
data. It goes with the Code with Sam video on GraphQL with Spring Boot, and every
number in that video comes out of `scripts/verify.sh`.

- **Spring Boot 4.1.1** with **Spring for GraphQL 2.0.5**, Spring Security and WebSocket
- **Postgres 17**, with every statement logged so queries can be counted
- **JDK 25**

## Run it

Needs Docker, JDK 25, Node 20 or later and `jq`.

```bash
scripts/verify.sh
```

`verify.sh` starts Postgres, builds and starts the shop, and checks every result
below. It lays each mistake in `mistakes/` over a scratch copy of the shop, never
the shop itself, and fails loudly if any result stops being true. It ends with
`ALL CLAIMS HOLD`.

To try a query yourself once it is up:

```bash
scripts/ask.sh '{ order(id: 1) { status amount customer { name } lines { quantity product { name } } } }'
```

The demo users `clerk` and `admin` (passwords the same as the names) exist only
for the field security example. They are in memory and not for real use.

## What it measures

| # | Claim | Result on 26 September 2026 |
|---|---|---|
| 0 | The query language | one document with variables, an alias, a fragment and `@include`; the lines appear and disappear with the variable |
| 1 | REST against GraphQL | the order list screen: REST 21 requests and 2,410 bytes, GraphQL 1 request and 1,608 bytes. The detail screen: 1,124 bytes against 135. This application, not a law |
| 2 | N plus one, three levels | `@SchemaMapping`: 20 customer, 20 order line and 40 product selects for one request. `@BatchMapping`: 1, 1 and 1 |
| 3 | Errors | with no exception resolver a missing order is masked as `INTERNAL_ERROR`; with one it is `NOT_FOUND`, data and errors in one response |
| 4 | Status codes | the same broken queries: 200 under `application/json`, 400 under `application/graphql-response+json`; a missing order is 200 either way; `GET` on this endpoint is 405 |
| 5 | Field security | `@PreAuthorize` on the email field: anonymous `UNAUTHORIZED`, clerk `FORBIDDEN`, admin sees it; the name arrives every time |
| 6 | Cursor pagination | `ScrollSubrange` in, `Window` out: page two is 4, 5, 6. This implementation's cursor decodes to a key set position |
| 7 | Aliases | 60 aliases at depth two pass a depth limit and run 60 selects; a complexity limit rejects them at 120 over 100 |
| 8 | Introspection | off with one property; on by default |
| 9 | A field nobody resolves | returns null with no error; the startup schema inspection report names it |
| 10 | Subscriptions | subscribe to order 5 over WebSocket, ship it, the event arrives |
| 11 | Slice tests | `@GraphQlTest` with `GraphQlTester`, no database: 2 tests pass |
| 12 | Schema evolution | `total` deprecated still answers; removed, the old query fails with a 400 validation error |
| 13 | What a data loader remembers | one product select for one request, and one more for the same request again: the cache lives for one request |

Versions and defaults change. Everything here was true on the date above; the
script is how you check it is still true today.

## Mistakes, one folder each

| Folder | What it changes |
|---|---|
| `n-plus-one` | one query per parent with `@SchemaMapping` |
| `no-exception-resolver` | removes the exception resolver |
| `depth-only` | a depth limit with no complexity limit |
| `introspection-default` | leaves introspection at its default |
| `unmapped-field` | adds `trackingNumber` to the schema with no resolver |
| `field-removed` | removes the deprecated `total` field |
