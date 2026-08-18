# ananke

**Your infrastructure is a value in your source code. The compiler checks it,
and refuses to produce a binary if it is wrong.**

There is no `docker-compose.yaml` in this repository to keep in sync with the
code. There is a topology in [`src/infra.zig`](src/infra.zig), and the compose
file is an *output* of building the program — verified, generated, and
overwritten every time.

```
zig build test     # 35 unit tests, plus 12 files that must fail to compile
zig build emit     # write the generated config into generated/
zig build run      # show the verified plan
```

Named after the Greek personification of necessity: the constraint nobody, not
even a god, gets to argue with.

---

## What it looks like when you get it wrong

```zig
.links = &.{
    .{ .from = "web", .to = "db", .port = "sql" },
},
```

```
src/verify.zig:27:9: error:
    ANANKE: infrastructure rejected, nothing was built

      topology  zone-jump
      source    examples/violations/zone_jump.zig
      verdict   1 violation, 2 warning(s) not shown

      [1/1] zone-boundaries
            rule   A service may reach its own trust tier or exactly one tier deeper
            where  web (dmz) -> db (restricted)
            what   connection crosses 2 trust tiers in one hop
            fix    route it through a service in the tier between them

      No binary was produced and no config was generated.
      Fix the topology above and the build turns green.
```

That is the whole idea. Not a linter you remember to run, not a CI job that
tells you twenty minutes later: the frontend cannot reach the database because
a program that does is not a program this compiler will build.

## What it looks like when you get it right

```zig
const ananke = @import("ananke");

pub const topology: ananke.Topology = .{
    .name = "ananke-demo",
    .source = "src/infra.zig",
    .services = &.{
        .{
            .name = "edge",
            .zone = .public,
            .image = "nginx:1.27-alpine",
            .ports = &.{
                .{ .name = "https", .number = 443, .proto = .https, .expose = .public },
            },
            .health = .{ .port = "https" },
        },
        .{
            .name = "api",
            .zone = .internal,
            .replicas = 3,
            .ports = &.{.{ .name = "http", .number = 8081, .proto = .http }},
            .env = &.{ananke.Env.secret("DATABASE_PASSWORD", "POSTGRES_PASSWORD")},
            .health = .{ .port = "http" },
        },
        .{
            .name = "db",
            .zone = .restricted,
            .image = "postgres:16-alpine",
            .ports = &.{.{ .name = "sql", .number = 5432, .proto = .postgres }},
            .health = .{ .port = "sql" },
        },
    },
    .links = &.{
        .{ .from = "api", .to = "db", .port = "sql" },
    },
};

// Verification happens here, while this declaration's type is constructed.
pub const plan = ananke.Plan(topology, .{});
```

`plan` cannot exist unless every policy passed. Everything downstream —
generated config, port numbers, sockets — hangs off it, so there is no path
from a topology to a running process that skips the checks.

## The three phases

| phase | when | what runs |
| --- | --- | --- |
| **parse** | compile time | your topology is read as ordinary Zig data — structs and slices, no parser, no schema file |
| **verify** | compile time | every policy runs over that data; one denial reaches `@compileError` and the build stops |
| **generate** | compile time | compose, nginx, graphviz and Markdown are assembled into string constants |
| **run** | run time | the only code in the binary: sockets bound to numbers the policy pass approved |

### One honest caveat about phase three

Zig's `comptime` has no I/O. It cannot open a file, and any design that claims
to write config files *during* compilation is describing something the language
does not do.

What it can do — and what this does — is decide every byte of those files at
compile time. `plan.compose_yaml` is a `[]const u8` fully assembled while the
compiler is running and baked into the binary as a constant. `zig build emit`
then copies those constants to disk. The generation is genuinely compile-time;
only the `write(2)` is not. Practically the difference is invisible: one build
command, files appear, they cannot disagree with the code that produced them.

## What is checked

Twelve policies ship in [`src/policies.zig`](src/policies.zig). All of them are
optional, and all of them are ordinary code you could have written yourself.

| policy | denies |
| --- | --- |
| `service-names` | duplicate names, or names that cannot be hostnames |
| `unique-ports` | two published services on one port; one service declaring a port twice |
| `valid-links` | links to a service or port that does not exist; self-links |
| `zone-boundaries` | connections that skip a trust tier, or flow outward |
| `no-published-datastores` | anything in the restricted tier with a published port |
| `encrypted-edges` | internet-facing ports speaking plaintext |
| `privileged-ports` | ports below 1024 anywhere but the public edge |
| `replica-sanity` | zero replicas; several replicas fighting over one host port |
| `no-plaintext-secrets` | credential-shaped env vars holding literal values |
| `no-dependency-cycles` | a link graph with no possible start order |
| `health-checks` | probes pointing at ports the service does not declare |
| `no-orphans` | *(warning)* services nothing links to and nothing publishes |

Warnings are the interesting case. A compiler cannot print without failing —
there is no stdout at compile time, only the ability to stop. So warnings are
collected during compilation, carried into the binary, and printed by
`ananke plan`. Advice you are allowed to ignore does not get to stop your build.

### The trust model

Four tiers, and connections may travel inward one tier at a time:

```
public  ──▶  dmz  ──▶  internal  ──▶  restricted
 edge        gateway    api, worker    db, cache, queue
```

`public → internal` skips a tier: compile error. `restricted → dmz` flows
outward: compile error. This is enforced twice over, because the generated
compose file puts each tier on its own network and attaches a service only to
its own tier plus the tiers it has links into — so a container that was never
granted a link has no route, not merely no permission.

## Code cannot dial what policy did not permit

The link graph is not documentation about what the program does. It is the only
way the program can obtain an address:

```zig
const db = plan.endpoint("api", "db", "sql");    // ok: that link exists
const oops = plan.endpoint("gateway", "db", "sql");
// error: ananke: 'gateway' has no link to 'db:sql', so it is not
//        allowed to connect there.
```

Same for ports and sockets. `plan.port("db", "sql")` is a compile-time lookup,
so renaming a port breaks the build rather than the deployment, and
`plan.Listeners("gateway")` produces a socket array sized and numbered from the
topology — no config parsing, no port validation at startup, nothing left to
get wrong:

```
$ ananke serve
listening on 127.0.0.1:9100  (metrics, http)
```

## Writing your own policy

A policy is any namespace with three declarations:

```zig
const NoRedis = struct {
    pub const id = "no-redis";
    pub const title = "This shop does not run Redis";

    pub fn check(comptime t: ananke.Topology) []const ananke.Finding {
        comptime var out: []const ananke.Finding = &.{};
        inline for (t.services) |s| {
            inline for (s.ports) |p| {
                if (p.proto != .redis) continue;
                out = out ++ [_]ananke.Finding{.{
                    .subject = s.name,
                    .message = "speaks redis",
                    .fix = "use the database",
                }};
            }
        }
        return out;
    }
};

const plan = ananke.Plan(topology, .{ .extra = &.{NoRedis} });
```

Namespaces rather than function pointers, deliberately: a `check` needs its
topology as a `comptime` parameter so it can build its result with `++`, and a
function with a comptime parameter has no runtime address to store. Passing
policies as `[]const type` keeps every check in the comptime world.

Replace the whole set with `.{ .policies = &.{...} }`, or start from
`ananke.policies.structural_only` — the subset that cannot produce a false
positive — when adopting this on a system whose security posture is, let us say,
aspirational.

## Testing a checker

A checker whose failures are untested is a checker that quietly stops failing.
Every policy is tested twice:

- [`src/test_policies.zig`](src/test_policies.zig) runs policies through
  `verify.audit`, which returns findings instead of halting, and asserts on both
  the clean and the dirty case.
- [`examples/violations/`](examples/violations) holds twelve files that **must
  not compile**. `zig build violations` compiles each one and fails if the build
  succeeds, or if it fails for the wrong reason.

Each violation file is also the shortest possible explanation of what a policy
is for.

## Layout

```
src/
  schema.zig        the vocabulary: Zone, Protocol, Port, Service, Link, Topology
  policy.zig        the policy interface and the audit engine
  policies.zig      the twelve policies that ship
  verify.zig        the @compileError, and the message it prints
  plan.zig          Plan(): the only door from a topology to anything else
  runtime.zig       the only code that reaches the binary: sockets
  emit/             compose, nginx, graphviz and Markdown generators
  infra.zig         the demo topology
  main.zig          the demo CLI
examples/violations/  twelve files that must not compile
generated/            checked in, so infrastructure changes show up in diffs
```

## Requirements

Zig 0.16.0. No dependencies.

## License

MIT.
