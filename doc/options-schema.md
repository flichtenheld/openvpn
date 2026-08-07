# OpenVPN Option Schema — Design Specification

**Status:** Draft / design proposal
**Scope:** Defines a declarative schema (authored as YAML) that will become the single
source of truth for OpenVPN's command-line and configuration options, and describes how C
code is generated from it.

This document is a *specification of the format*, written before any schema data or code
generator exists, so the design can be reviewed and validated first. Nothing here changes
the build or the parser yet.

---

## 1. Overview & rationale

### 1.1 The problem

Today everything known about each of the ~300–320 OpenVPN options lives *only in C code*,
expressed procedurally and duplicated across four locations in `src/openvpn/`:

| Location | File / lines | Role |
| --- | --- | --- |
| `add_option()` | `options.c` 5609–9334 (~3,725 lines) | one `if / else if (streq(p[0], "name"))` branch per option — parses and applies it |
| `remove_option()` | `options.c` 5099 | per-option reset logic (`--pull-filter`, connection reset) |
| `update_option()` | `options.c` 5419 | per-option "reset-once then re-add" logic for `PUSH_UPDATE` |
| `usage_message[]` | `options.c` 122–790 | a monolithic `printf`-format `--help` string |

For every option, the following facts are recoverable only by reading code:

- **name** and **aliases** (`streq(p[0], "a") || streq(p[0], "b")`)
- **argument count** — encoded as guard predicates such as `p[1] && !p[2]`
- **per-argument type** — via ad-hoc helpers (`positive_atoi`, `get_ip_addr`, …)
- **permission mask** — `VERIFY_PERMISSION(OPT_P_...)`
- **inline-ability** — whether the option may come from an inline `<tag>…</tag>` block
- **scope** — global (`options->x`) vs per-connection (`options->ce.x`)
- **availability** — `#ifdef`/`#if defined(...)` feature guards
- **deprecation status** — bespoke `msg(M_WARN, "DEPRECATED …")` branches
- **short help text** — the hand-maintained `usage_message`, which drifts from reality
  because nothing machine-checks it against the real option names

### 1.2 The goal

Move all of that metadata into one declarative file, `src/openvpn/options.yml`, and generate
a getopt_long-style **descriptor table** that a rewritten `add_option()` loops over. This:

- removes the ~3,700-line `if/else` chain in favour of a table lookup + dispatch,
- makes `--help`, the parser, and the reset/update paths consistent by construction,
- gives every option a single, reviewable definition,
- and lets tooling (docs, shell completion, sync checks) consume the same source of truth.

### 1.3 Chosen build model (no new build dependency)

The schema is **authored in YAML**, but the generated C is **committed to the tree**. The
generator runs only when a maintainer edits the schema — it is *not* part of an ordinary
build. Consequences:

- Ordinary `autotools` and `cmake` builds compile the committed `*.gen.c`/`*.gen.h` like any
  other source and gain **no** new dependency. This matters because the autotools path
  currently requires no Python at all, and nothing in the tree parses YAML.
- The generator (`dev-tools/gen-options.py`) needs Python 3 + PyYAML, required only on a
  maintainer's machine at regeneration time.
- The generator also emits a stdlib-parseable JSON sidecar (`options_schema.gen.json`) so
  tests and CI can validate the schema with the Python standard library alone (no PyYAML).
- A CI check regenerates in a scratch dir and byte-compares against the committed output, so a
  stale committed file fails the build. This is what makes "commit the generated file" safe.

### 1.4 Relationship to the man pages

The schema becomes authoritative for the **short** `--help` text (`help.short`). The
**long-form** documentation stays in `doc/man-sections/*.rst`, which each option links to via
`help.man_ref`. A future lint can cross-check that every option is documented.

---

## 2. Per-option field taxonomy

Each option is one entry in the top-level `options:` list. Fields, grouped by role:

### 2.1 Identity

| Field | YAML type | Req. | Maps to / notes |
| --- | --- | --- | --- |
| `name` | string | **required** | the canonical `streq(p[0], "name")` token |
| `aliases` | list&lt;string&gt; | optional | extra `\|\| streq(p[0], …)` synonyms |

`aliases` is purely an **authoring** convenience: the generator expands each option into one
table row per name (canonical + every alias), all sharing the same dispatch `key`. Lookup is
therefore a single binary search over the sorted table — there is no separate alias index (§6).
Because each row's `name` *is* the token that matched, the handler distinguishes aliases just by
reading `p[0]` (equivalently `d->name`), which is how branches like `redirect-gateway` vs
`redirect-private` (`options.c:7030`) stay separable.

### 2.2 Arguments

| Field | YAML type | Req. | Maps to / notes |
| --- | --- | --- | --- |
| `args` | list&lt;arg-spec&gt; | optional (default `[]`) | positional parameters `p[1]`, `p[2]`, … |

**Arity is derived, not authored.** From the `args` list the generator computes:

- `min_args` = number of args **without** `optional: true`
- `max_args` = total number of args, or unbounded when the last arg has `variadic: true`

and emits the exact guard that is written by hand today, e.g. `p[min] && !p[max+1]`. This
replaces the single most error-prone hand-written construct in `add_option`. Examples:

- `dev` (exactly one arg) → `min=1, max=1` → `p[1] && !p[2]`
- `remote` (1–3 args) → `min=1, max=3` → `p[1] && !p[4]`
- `remote-random` (no args) → `min=0, max=0` → `!p[1]`
- `echo` (unbounded) → `min=0, max=MAX_PARMS`, `variadic: true`

Each **arg-spec** is a mapping:

| Field | YAML type | Req. | Notes |
| --- | --- | --- | --- |
| `name` | string | **required** | token used in docs/usage (`host`, `port`, `n`) |
| `type` | enum | **required** | one of the arg types in §3 |
| `optional` | bool | optional | trailing optional arg → raises `max_args`, not `min_args` |
| `variadic` | bool | optional | only on the last arg; unbounded tail up to `MAX_PARMS` |
| `range` | `[min, max]` | optional | required for `int-range`; values may be symbolic (§3) |
| `values` | list&lt;string&gt; | optional | required for `enum` |
| `default` | scalar/symbol | optional | for usage-text interpolation only (§6) |
| `validate` | bool (default `true`) | optional | `false` = generator does *not* validate; the handler re-parses (avoids double error messages) |

### 2.3 Classification & gating

| Field | YAML type | Req. | Maps to / notes |
| --- | --- | --- | --- |
| `permission` | list&lt;`OPT_P_*`&gt; | **required** | the mask ORed into `VERIFY_PERMISSION(...)` (`options.h:728–759`) |
| `inline` | bool (default `false`) | optional | adds `OPT_P_INLINE`; option may appear in an inline `<tag>` block |
| `connection_scope` | `false` \| `true` \| `dual` | optional | see below |

`connection_scope` is tri-state:

- `false` — global option; target is `options->x`.
- `true` — per-connection; adds `OPT_P_CONNECTION`; target is `options->ce.x`.
- `dual` — the option is legal both globally and inside a `<connection>` block, and the
  handler chooses `options->x` vs `options->ce.x` from `permission_mask` **at runtime**. This
  cannot be a static assignment and therefore forces a Tier-B handler (§4). Examples:
  `remote` (`options.c:6145/6154`), `key-direction` (`8370/8374`), `tls-auth` (`9019/9034`).

`inline` and `connection_scope` are convenience booleans that fold into the permission mask,
but are kept distinct because they carry meaning for documentation and for the handler
target convention.

### 2.4 Availability (feature guards)

| Field | YAML type | Req. | Maps to / notes |
| --- | --- | --- | --- |
| `available_if` | feature expression | optional | the wrapping `#if` / `#ifdef` / `#ifndef` |

`available_if` is a small boolean expression over a **closed set** of feature tokens that
mirror the C preprocessor macros. Grammar:

```yaml
available_if: WIN32                          # #ifdef _WIN32   (leading _ optional in token)
available_if: {not: ENABLE_CRYPTO_MBEDTLS}   # #ifndef ENABLE_CRYPTO_MBEDTLS
available_if: {all_of: [ENABLE_DEBUG, {not: ENABLE_SMALL}]}   # #if defined(ENABLE_DEBUG) && !defined(ENABLE_SMALL)
available_if: {any_of: [_WIN32, TARGET_ANDROID]}
```

The closed token set (extend deliberately, alongside the generator): `WIN32`, `TARGET_LINUX`,
`TARGET_ANDROID`, `TARGET_FREEBSD`, `ENABLE_MANAGEMENT`, `ENABLE_PKCS11`, `ENABLE_PLUGIN`,
`ENABLE_CRYPTO_MBEDTLS`, `ENABLE_CRYPTO_OPENSSL`, `ENABLE_SMALL`, `ENABLE_LZO`, `ENABLE_LZ4`,
`ENABLE_FRAGMENT`, `ENABLE_DEBUG`, `ENABLE_SELINUX`, `PORT_SHARE`, `UNIX_SOCK_SUPPORT`, ….

The generator wraps the option's **table row** (and its handler `case`) in the matching
preprocessor conditional, so an unavailable option is simply absent from the table and falls
through to the existing "unknown option" path — exactly as an `#ifdef`-compiled-out `else if`
behaves today. `available_if` covers only **whole-option** presence; an *interior* `#ifdef`
inside a body (e.g. `dhcp-option`, `options.c:7965`) stays inside the hand-written handler.

### 2.5 Lifecycle / deprecation

| Field | YAML type | Req. | Notes |
| --- | --- | --- | --- |
| `status` | `active` \| `deprecated` \| `removed` \| `ignored` | optional (default `active`) | |
| `status_message` | string | optional | the warning/error text |
| `replacement` | string | optional | "use `--X` instead" |
| `since` / `removed_in` | version string | optional | documentation metadata |

Generator behaviour:

- `deprecated` → emit the warning, then still run the action.
- `removed` → emit an error and `goto err` (no action).
- `ignored` → warn (optional), consume the args, no action.

This absorbs a large family of near-identical branches (e.g. `mtu-dynamic` at `options.c:6485`,
`http-proxy-retry` at `6726`, `windows-driver` at `5902`) with zero hand-written code.

### 2.6 Action linkage

| Field | YAML type | Req. | Notes |
| --- | --- | --- | --- |
| `handler` | `set:` map **or** `call:` string | required unless `status` is `removed`/`ignored` | selects declarative vs hand-written action (§4) |

### 2.7 Help

| Field | YAML type | Req. | Notes |
| --- | --- | --- | --- |
| `help.short` | string | optional | one/multi-line `--help` description (may contain named placeholders, §6) |
| `help.section` | string | optional | section header for grouping, e.g. `"Tunnel Options"` |
| `help.order` | int | optional | stable ordering within a section |
| `help.man_ref` | string | optional | anchor into `doc/man-sections/*.rst` for long-form docs |

---

## 3. Argument type catalog

A **closed, versioned** set of argument types. Each maps to an existing helper (mostly in
`src/openvpn/options_util.{c,h}`); the generator emits a validation call in the prolog and, on
failure, `msg(msglevel, …); goto err;`. Adding a new type is a deliberate act (new template +
helper binding), which keeps the escape hatch honest.

| Type | Meaning | Backing check |
| --- | --- | --- |
| `string` | opaque, no validation | (none) — direct assign |
| `int` | any integer | `valid_integer(s, false)` |
| `positive-int` | integer ≥ 0 | `positive_atoi` / `valid_integer(s, true)` |
| `int-range` | integer in `range:[min,max]` | `atoi_constrained(s, &v, name, min, max, msglevel)` |
| `port` | 0–65535 (alias of `int-range`) | `atoi_constrained(..., 0, 65535, ...)` |
| `bool-flag` | option present ⇒ true; **zero args** | direct `= true` |
| `enum` | one of `values:` | generated `streq` chain, else error |
| `ipv4` | dotted-quad address | `get_ip_addr` |
| `ipv6` | IPv6 literal | `get_ipv6_addr` |
| `ip-or-host` | address or DNS name | `ip_or_dns_addr_safe` |
| `proto` | `udp`/`tcp*`/… | `ascii2proto` (+ `ascii2af`) |
| `af` | address family token | `ascii2af` |
| `keydirection` | `0`/`1`/bidirectional | `ascii2keydirection` |
| `topology` | `subnet`/`net30`/`p2p` | `parse_topology` |
| `mac` | MAC address | `mac_addr_safe` |
| `filename` | path; not inline-capable | direct assign |
| `inline-file` | path **or** inline `<tag>` | emits `X_file = p[i]; X_file_inline = is_inline` |

Notes:

- **Symbolic bounds/defaults.** `range` and `default` values may be symbolic C tokens (e.g.
  `TUN_MTU_MAX`, `TUN_MTU_MAX_MIN`, `PING_TIMEOUT_MAX`). The generator emits them verbatim into
  C, so the schema tracks the macros instead of duplicating numeric literals.
- **Advisory validation seam.** For options whose handler already re-parses an argument (e.g.
  `remote` re-runs `ascii2proto`), set `validate: false` on that arg so the generator performs
  only arity/permission checks and leaves parsing to the handler — avoiding duplicate error
  messages. This is the pragmatic boundary between "generator validates" and "handler validates".

---

## 4. Two-tier action model

The bodies of the ~380 branches range from a single assignment to multi-level sub-grammars.
The schema models this with two tiers; the presence of `set:` vs `call:` under `handler` is
the single switch between them.

### 4.1 Tier A — declarative `set:` (no C written)

For the large class of trivial actions, the schema names the target and the generator emits
the assignment. Forms:

`set:` is either a **single** assignment or a **list** of assignments (for options with more
than one argument). Forms:

```yaml
handler: {set: {field: dev, from: arg1}}                           # string assign  (options.c:5894)
handler: {set: {field: remote_random, value: true}}               # bool           (6031)
handler: {set: {flag_field: management_flags, or: MF_QUERY_PASSWORDS}}  # flag-OR   (5765)
handler: {set: {field: ce.tun_mtu_max, from: arg1, type: int-range}}   # ranged int (6454)
handler: {set: {inline_file: ca_file, from: arg1}}                # inline file    (8629–8630)

# multiple trivial arguments -> a LIST of assignments, one per slot (options.c:7383–7394)
handler:
  set:
    - {field: cf_max, from: arg1}      # p[1]; type/bounds come from the arg slot (int-range 1..INT_MAX)
    - {field: cf_per, from: arg2}      # p[2]; same
```

- `from: argN` selects the source token `p[N]`; a list assigns several fields from several slots.
- `field` may be dotted (`ce.tun_mtu_max`) to select the per-connection target.
- `inline_file: ca_file` expands to both `options->ca_file = p[1]` and
  `options->ca_file_inline = is_inline`.
- The type/bounds used to convert an argument come from the option's per-slot `args`
  descriptor (§6.1), so the `set` assignment need not repeat them — for `connect-freq`,
  `validate_argtypes()` runs `atoi_constrained(..., 1, INT_MAX, ...)` on each slot and the
  assignment just stores the converted integers. An explicit `type:` on a `set` entry is only
  needed when there is no matching typed arg slot.
- The generator learns each field's C type from a small **field catalog** (derived from
  `struct options` / `struct connection_entry`).

Tier A is expected to absorb the majority of options.

### 4.2 Tier B — named handler `call:` (escape hatch)

For everything with real logic — sub-dispatch (`dhcp-option`, `http-proxy-option`, `dns`,
`setenv`), recursion (`config`, `connection`), cross-option side effects, `dual` scope, and
interior `#ifdef`s — the schema names a handler:

```yaml
handler: {call: add_opt_dhcp_option}
```

The generator emits a dispatch entry keyed by a stable enum value (§6). The handler receives a
**shared context struct** carrying exactly what today's giant function has in scope:

```c
struct add_option_ctx {
    struct options *options;
    char          **p;              /* tokenized argv; p[0] == matched name */
    const char     *matched_name;   /* which alias matched                 */
    bool            is_inline;
    uint64_t        permission_mask;
    uint64_t       *option_types_found;
    msglvl_t        msglevel;
    struct env_set *es;
    const char     *file;
    int             line;
    int             level;
};
```

Because the context mirrors the current locals, migrating a branch is a mechanical *lift* of
its body into a handler function — not a rewrite.

### 4.3 Sub-dispatch and the `subcommands:` field (doc-only, future)

Options whose second token selects a sub-form (e.g. `dhcp-option DOMAIN … | DNS … | …`) are
Tier B in v1: the schema records `args: [{name: type, type: string}, {variadic}]` plus
`handler.call`, and the sub-grammar stays in C. An optional, initially **doc-only**
`subcommands:` map may describe the sub-forms for documentation and shell completion without
generating any action code:

```yaml
subcommands:
  DOMAIN:        {args: [{name: name, type: string}], help: "Set connection-specific DNS domain."}
  DNS:           {args: [{name: addr, type: ip-or-host}], help: "Set DNS server address."}
```

---

## 5. Worked examples

Each example is annotated with the `options.c` branch it replaces.

```yaml
options:

  # (a) trivial bool  — options.c:6028
  - name: remote-random
    args: []
    permission: [OPT_P_GENERAL]
    handler: {set: {field: remote_random, value: true}}
    help: {short: "Random selection order for --remote hosts.", section: "Tunnel Options"}

  # (b) simple string  — options.c:5891
  - name: dev
    args:
      - {name: "tunX|tapX|null", type: string}
    permission: [OPT_P_GENERAL]
    handler: {set: {field: dev, from: arg1}}
    help: {short: "tun/tap device to use.", section: "Tunnel Options"}

  # (c) ranged int, per-connection scope  — options.c:6451
  - name: tun-mtu-max
    args:
      - name: n
        type: int-range
        range: [TUN_MTU_MAX_MIN, TUN_MTU_MAX]   # symbolic tokens, emitted verbatim
        default: TUN_MTU_MAX_MIN
    permission: [OPT_P_MTU]
    connection_scope: true                       # target is options->ce.tun_mtu_max
    handler: {set: {field: ce.tun_mtu_max, from: arg1}}   # bounds come from the arg slot above
    help: {short: "Maximum pushable MTU (default and minimum=%(default)d).", section: "Tunnel Options"}

  # (c2) MULTIPLE trivial arguments  — options.c:7383
  - name: connect-freq
    args:
      - {name: n, type: int-range, range: [1, INT_MAX]}   # p[1] -> cf_max
      - {name: s, type: int-range, range: [1, INT_MAX]}   # p[2] -> cf_per
    permission: [OPT_P_GENERAL]
    handler:
      set:
        - {field: cf_max, from: arg1}
        - {field: cf_per, from: arg2}
    help: {short: "Allow a maximum of n new connections per s seconds.", section: "Server Options"}

  # (d) inline-capable file  — options.c:8626
  - name: ca
    args:
      - {name: file, type: inline-file}
    permission: [OPT_P_GENERAL]
    inline: true                                 # adds OPT_P_INLINE
    handler: {set: {inline_file: ca_file, from: arg1}}   # ca_file + ca_file_inline = is_inline
    help: {short: "Certificate authority file in .pem format.", section: "TLS Options"}

  # (e) aliased multi-name, Tier B  — options.c:7014
  - name: redirect-gateway
    aliases: [redirect-private]
    args:
      - name: flags
        type: enum
        variadic: true
        values: [local, autolocal, def1, bypass-dhcp, bypass-dns, block-local, ipv6, "!ipv4"]
        validate: false                          # handler validates each flag
    permission: [OPT_P_ROUTE]
    handler: {call: add_opt_redirect_gateway}    # branches on matched_name; sets routes->flags; setenv
    help: {short: "Automatically redirect all traffic through the VPN.", section: "Client Options"}

  # (f) complex sub-dispatch, Tier B  — options.c:7962
  - name: dhcp-option
    args:
      - {name: type, type: string}
      - {name: args, type: string, variadic: true, validate: false}
    permission: [OPT_P_DHCPDNS]
    handler: {call: add_opt_dhcp_option}         # interior #ifdef stays in the handler
    help: {short: "Set extended TAP options for DHCP.", section: "Windows Options"}
    subcommands:                                 # doc-only for now
      DOMAIN:        {args: [{name: name, type: string}], help: "Set connection-specific DNS domain."}
      DOMAIN-SEARCH: {args: [{name: name, type: string}], help: "Add domain to the DNS search list."}
      DNS:           {args: [{name: addr, type: ip-or-host}], help: "Set DNS server address."}
```

A `dual`-scope option would appear as `connection_scope: dual` with
`permission: [OPT_P_GENERAL, OPT_P_CONNECTION]` and `handler: {call: add_opt_remote}`.

---

## 6. Generated-artifact shape

The generator emits three committed files, each written only when its content changes
(mirroring `contrib/cmake/parse-version.m4.py`).

### 6.1 `src/openvpn/options_table.gen.h`

```c
typedef enum {
    OPT_ARG_NONE = 0,
    OPT_ARG_STRING,
    OPT_ARG_INT,        /* positive_atoi / atoi family */
    OPT_ARG_INT_RANGE,  /* atoi_constrained, bounds from opt_arg_t.imin/imax */
    OPT_ARG_IP,
    OPT_ARG_IP6,
    OPT_ARG_HOST,       /* ip_or_dns_addr_safe */
    OPT_ARG_ENUM,       /* value checked against opt_arg_t.values */
    OPT_ARG_INLINE_FILE,
    /* ... */
} opt_argtype_t;

/* One positional argument slot. An option's args are an ARRAY of these — index i
 * describes p[i+1]. This is what "per-slot" means: a two-argument option carries a
 * two-element array, each element with its own type and (for INT_RANGE/ENUM) its own
 * bounds/allowed-values. */
typedef struct {
    opt_argtype_t      type;
    const char        *name;    /* arg name, for usage text and error messages   */
    int                imin;     /* INT_RANGE lower bound (else unused)           */
    int                imax;     /* INT_RANGE upper bound (else unused)           */
    const char *const *values;   /* ENUM allowed values, NULL-terminated, or NULL */
    bool               optional; /* trailing optional arg                         */
    bool               validate; /* false => handler re-parses; skip generic check*/
} opt_arg_t;

/* Stable dispatch key. Emitted UNCONDITIONALLY (never #ifdef-wrapped) so the
 * numbering is identical across build configurations. */
typedef enum {
    OPT_KEY_help = 0,
    OPT_KEY_version,
    OPT_KEY_dev,
    OPT_KEY_dhcp_option,
    /* ... one per option ... */
    OPT_KEY__COUNT
} opt_key_t;

typedef struct {
    const char          *name;        /* this row's name (canonical OR an alias) */
    uint8_t              min_args;     /* required args after p[0]             */
    uint8_t              max_args;     /* upper bound (encodes the !p[N] guard)*/
    uint64_t             permission;   /* OPT_P_* mask                         */
    uint32_t             flags;        /* OPTDESC_INLINE_OK | _DEPRECATED | _ALIAS | ...*/
    const opt_arg_t     *args;        /* per-slot arg descriptors (length max_args), or NULL;
                                         for a variadic option the last slot applies to the tail */
    opt_key_t            key;          /* dispatch key (shared across a name and its aliases) */
    const char          *help;         /* short help; NULL in ENABLE_SMALL builds (see OPT_HELP) */
} opt_desc_t;

/* Help/usage text is stripped from --small builds, exactly as the whole
 * usage_message is today (options.c:4874 prints "Usage message not available"
 * under ENABLE_SMALL). The generator wraps every help string in OPT_HELP so the
 * string literals are dropped from the binary — the field stays in the struct
 * (to keep the row layout config-independent) but reads back as NULL. */
#ifdef ENABLE_SMALL
#define OPT_HELP(text) NULL
#else
#define OPT_HELP(text) (text)
#endif

extern const opt_desc_t openvpn_option_table[];
extern const size_t      openvpn_option_table_len;
```

The `help.section`/`help.order` metadata (used only to group and order `--help` output) is
likewise needed only in non-small builds; the generator emits it in a parallel array guarded by
`#ifndef ENABLE_SMALL`, so it too vanishes from small builds along with `usage()`.

### 6.2 `src/openvpn/options_table.gen.c`

The static descriptor table, **sorted by name** (so lookup can binary-search), with each row
wrapped in its `available_if` `#if`:

The `args` arrays are small per-slot descriptor tables the generator emits (and de-duplicates)
above the main table; each `opt_desc_t` row points at the one describing its arguments:

```c
#include "syshead.h"
#include "options_table.gen.h"

/* single string argument */
static const opt_arg_t args_dev[] = {
    { OPT_ARG_STRING, "tunX|tapX|null", 0, 0, NULL, false, true },
};
/* single inline-capable file */
static const opt_arg_t args_ca[] = {
    { OPT_ARG_INLINE_FILE, "file", 0, 0, NULL, false, true },
};
/* TWO int-range slots, each with its own bounds — this is the multi-arg case */
static const opt_arg_t args_connect_freq[] = {
    { OPT_ARG_INT_RANGE, "n", 1, INT_MAX, NULL, false, true },
    { OPT_ARG_INT_RANGE, "s", 1, INT_MAX, NULL, false, true },
};
/* variadic tail of enum flags; handler validates each token */
static const char *const rg_flags[] = { "local", "def1", "bypass-dhcp", "block-local", NULL };
static const opt_arg_t args_redirect_gateway[] = {
    { OPT_ARG_ENUM, "flags", 0, 0, rg_flags, true /*optional*/, false /*handler validates*/ },
};

const opt_desc_t openvpn_option_table[] = {
    { "ca", 1, 1, OPT_P_GENERAL, OPTDESC_INLINE_OK,
      args_ca, OPT_KEY_ca, OPT_HELP("Certificate authority file in .pem format.") },
    { "connect-freq", 2, 2, OPT_P_GENERAL, 0,
      args_connect_freq, OPT_KEY_connect_freq,
      OPT_HELP("Allow a maximum of n new connections per s seconds.") },
    { "dev", 1, 1, OPT_P_GENERAL, 0,
      args_dev, OPT_KEY_dev, OPT_HELP("tun/tap device to use.") },
    /* an aliased option is simply two rows sharing one key; the alias row is
     * flagged so usage() lists the option only once */
    { "redirect-gateway", 0, MAX_PARMS, OPT_P_ROUTE, 0,
      args_redirect_gateway, OPT_KEY_redirect_gateway,
      OPT_HELP("Automatically redirect all traffic through the VPN.") },
    { "redirect-private", 0, MAX_PARMS, OPT_P_ROUTE, OPTDESC_ALIAS,
      args_redirect_gateway, OPT_KEY_redirect_gateway, NULL },
#ifdef _WIN32
    { "windows-driver", 1, 1, OPT_P_GENERAL, OPTDESC_DEPRECATED,
      args_dev, OPT_KEY_windows_driver, NULL },   /* deprecated: no help text */
#endif
    /* ... */
};
const size_t openvpn_option_table_len = SIZE(openvpn_option_table);
```

Notes:

- **Per-slot arguments.** `connect-freq` shows why `args` is an *array*: it has `min_args == max_args
  == 2` and a two-element `args_connect_freq[]`, each slot an independent `OPT_ARG_INT_RANGE` with
  its own `1..INT_MAX` bounds. `validate_argtypes()` (§6.4) walks the array against `p[1]`, `p[2]`,
  … running the matching helper per slot (here `atoi_constrained` twice, exactly reproducing
  `options.c:7388–7389`). A variadic option's last slot applies to every trailing token.
- **Aliases are just extra rows.** `redirect-gateway` and `redirect-private` are two rows with the
  same `OPT_KEY_redirect_gateway`; the alias row carries `OPTDESC_ALIAS` (and `NULL` help) so
  `usage()` prints the option once. Rows are emitted sorted across *all* names, so a single binary
  search resolves canonical names and aliases alike.
- Every help string is wrapped in `OPT_HELP(...)` (defined in §6.1) so the literals are compiled
  out of `ENABLE_SMALL` builds; rows with no help (deprecated or alias rows) use a bare `NULL`.

`#ifdef` discipline:

- The `opt_key_t` enum is **unconditional** — key numbering must not shift by configuration.
- Only the **table row** and the matching **handler `case`** are guarded. An unavailable option
  is absent from the table, so name lookup fails and the existing unknown-option path runs.
- **`ENABLE_SMALL`** does not gate whole rows — the option must still parse in a small build. It
  only strips the *help text* (via `OPT_HELP`) and the section/order metadata, matching today's
  behaviour where the parser is unchanged but `--help` is unavailable.

### 6.3 `src/openvpn/options_schema.gen.json`

A faithful JSON dump of the schema, parseable with the Python standard library `json` module,
consumed by the tests and CI sync checks (§8) so they need no PyYAML.

### 6.4 The rewritten `add_option()`

```c
void
add_option(struct options *options, char *p[], bool is_inline, ...)
{
    const opt_desc_t *d = option_lookup(p[0]);      /* single binary search over sorted rows */
    if (!d) { /* existing unknown-option handling */ return; }

    int nargs = count_args(p);                       /* replaces p[1] && !p[N] */
    if (nargs < d->min_args || nargs > d->max_args) { /* arity error */ goto err; }

    VERIFY_PERMISSION(d->permission);                /* macro unchanged */

    if (d->args && !validate_argtypes(d, p, msglevel)) { goto err; }  /* walks d->args, per slot */

    if (d->flags & OPTDESC_DEPRECATED) { /* emit status_message */ }

    switch (d->key) {                                /* actions (Tier A generated / Tier B lifted) */
        case OPT_KEY_dev:  options->dev = p[1]; break;
#ifdef _WIN32
        case OPT_KEY_windows_driver: msg(M_WARN, "DEPRECATED ..."); break;
#endif
        case OPT_KEY_dhcp_option: add_opt_dhcp_option(&ctx); break;
        /* ... */
    }
    return;
err:
    /* ... */
}
```

Design choices:

- **Lookup:** the table is generated with one row per name (aliases included), sorted by name → a
  single binary search resolves everything; no separate alias index. The generator can also emit a
  compile-time sortedness assertion. (Linear scan, as today, would be functionally fine; binary
  search removes any perf-regression concern for free.)
- **`verify_permission()` (`options.c:5007`) is reused unchanged** — the table only supplies the
  mask, so the context and inline checks keep working during and after migration.
- **Enum key + `switch`, not function pointers.** This keeps every handler `static` and local to
  `options.c`, keeps the table a pure `const` (ROM-able, no load-time relocations), and survives
  `#ifdef` cleanly (only the `case` is guarded, not the key).

### 6.5 `remove_option`, `update_option`, and `usage`

- `remove_option`/`update_option` consume the **same table** for name/arity/permission matching
  and dispatch through their own `switch (d->key)` of reset/update actions, gated by capability
  flags (`OPTDESC_REMOVABLE`, `OPTDESC_UPDATABLE`). A future schema field (`reset:`) can make
  these declarative too; treat that as out of scope for v1 (add-path first).
- `usage()` iterates the table printing `name` + `help` per `section`, under
  `#ifndef ENABLE_SMALL`, replacing the monolithic `usage_message`. See §7 for interpolation.

### 6.6 Owning the `--help` text (interpolation)

The current `usage_message` is one `printf` string whose `%d`/`%s` are filled from ~15
positional runtime defaults (`options.c:4883–4887`) — fragile because order and count must stay
in lockstep with the string. The schema replaces positional with **named** interpolation:

- Author `help.short: "... (default and minimum=%(default)d)"`, where `%(default)` refers to the
  arg's `default`, or `%(TUN_MTU_MAX_MIN)d` referring to a symbolic constant.
- The generator keeps a **default-constants catalog** mapping tokens to the C expression to
  interpolate, and lowers named placeholders to a deterministic builder. Values known only at
  runtime stay as named refs into the catalog; never inline literals.

---

## 7. Build integration

Because the generated files are committed, the wiring is minimal and symmetric — no
`BUILT_SOURCES`, no `add_custom_command`, no Python in either build.

### 7.1 `src/openvpn/Makefile.am`

Add the generated sources next to `options.c` in `openvpn_SOURCES`:

```
	options.c options.h \
	options_table.gen.c options_table.gen.h \
```

and distribute the schema + sidecar so tarballs and the sync check have them:

```
EXTRA_DIST += options.yml options_schema.gen.json
```

### 7.2 `CMakeLists.txt`

Add to `SOURCE_FILES`, sourced from the **source** dir (committed), not the binary dir:

```
    src/openvpn/options.c
    src/openvpn/options_table.gen.c
```

No `add_custom_command`. CMake already requires Python3, but we deliberately do not use it here
so both build paths behave identically with respect to the schema.

### 7.3 `dev-tools/gen-options.py` (maintainer only)

- Python 3 + PyYAML; same license header and `main()` + write-if-changed idiom as
  `contrib/cmake/parse-version.m4.py` and `git-version.py`.
- Reads `src/openvpn/options.yml`; writes the three `*.gen.*` files.
- Emits already-formatted C, and optionally runs `clang-format -i` on its outputs as a final
  step (guarded by "if `clang-format` is on `PATH`") so the committed C passes the
  `.pre-commit-config.yaml` hook. The generated files are **not** excluded from clang-format, so
  their diffs stay reviewable.
- Located in `dev-tools/` (alongside `update-copyright.sh`, `run-cppcheck.sh`) — signalling
  "maintainer tool", not a build step. `contrib/cmake/` is reserved for scripts the build runs.

### 7.4 Optional maintainer convenience targets

A non-default `regen-options` phony target in the root `Makefile.am` and a matching CMake
target may invoke the generator, mirroring the spirit of the existing `config-version.h`
`.PHONY` rule — but they are **never** prerequisites of anything, so an ordinary `make`/`cmake`
build never runs Python.

| | Ordinary build | Regen (maintainer) | CI staleness guard |
| --- | --- | --- | --- |
| Autotools | compiles committed `.gen.c` — no Python | `make regen-options` (PyYAML) | §8 check |
| CMake | compiles committed `.gen.c` — no Python | `regen-options` target (PyYAML) | §8 check |

---

## 8. Migration & verification strategy

### 8.1 Incremental migration (no big-bang)

The table coexists with the legacy chain because lookup can fall through:

- **Phase 0 — infra, zero behavior change.** Add `options.yml`, generate the table + JSON, wire
  the build. `add_option` still runs the legacy chain, but a debug-only **shadow check** looks up
  `p[0]` in the table and `ASSERT`s that its arity/permission match what the legacy branch
  enforces — surfacing schema/reality drift immediately.
- **Phase 1 — generic pre-checks.** Route name matching, arity, and `VERIFY_PERMISSION` through
  the table at the top of `add_option`; strip the `&& p[1] && !p[2]` clauses one option at a time.
- **Phase 2 — dispatch conversion, ~20 options per commit,** grouped by subsystem; each branch
  becomes a `set:` (Tier A) or a lifted `case` handler (Tier B). Convert whole `#ifdef` groups as
  units to keep guard pairing correct.
- **Phase 3** — convert `remove_option`/`update_option`/`usage` to table iteration.
- **Phase 4** — delete the dead legacy code and the shadow check.

### 8.2 Behavior-preservation tests

- **Dispatch test** — `tests/unit_tests/openvpn/test_options_parse.c` currently *mocks*
  `add_option` (it only tests `parse_line` tokenization). Add a fixture (or `test_options_dispatch.c`)
  that feeds `p[]` into the **real** `add_option` and asserts the resulting `struct options` field
  (e.g. `dev foo` → `options.dev == "foo"`), plus negative cases (wrong arity → error, wrong
  context → permission error). Register it in the autotools and CMake test lists.
- **Golden `--help`** — capture `openvpn --help` before the refactor and diff after (table-driven
  usage makes this exact); run under both a full-feature and a SMALL/`--disable`d config to
  exercise `#ifdef` gating.
- **Config-corpus differential** — parse a corpus of real and synthetic `.ovpn` files with the
  pre- and post-refactor binaries, dump the resulting `struct options` (via `show_settings()` /
  `options_string()`), and require zero diff.

### 8.3 Schema ↔ reality sync checks (CI, Python stdlib on the JSON sidecar)

1. **Staleness** — regenerate into a scratch dir and byte-compare against the committed
   `*.gen.*`. Fails if a maintainer edited `options.yml` without regenerating.
2. **Schema ⊇ reality** — every `streq(p[0], "…")` literal in `options.c` (and, during migration,
   the legacy chain) has a matching schema `name`/`alias`.
3. **Reality ⊇ schema** — every schema `name`/`alias` has a corresponding handler (`case` /
   `set:`).
4. **`#ifdef` pairing** — each option's `available_if` matches the guard wrapping both its table
   row and its handler case (prevents a row present when the handler is compiled out, or vice
   versa).
5. **Docs cross-check (optional)** — schema names vs `doc/man-sections/*.rst` to flag
   undocumented options.

Checks 2–4 are what prevent a hand-maintained table from silently diverging from the code.

---

## 9. Key risks & mitigations

| Risk | Mitigation |
| --- | --- |
| Dispatch-key numbering shifts across `#ifdef` configs | emit the full `opt_key_t` enum unconditionally (§6.1) |
| Maintainer forgets to regenerate | CI staleness check (§8.3.1) — the linchpin of the commit-generated model |
| clang-format drift on generated C | emit formatted output + optional `clang-format -i` at generation time (§7.3) |
| Bespoke per-option validation (MAC, enum, ranges) | keep in the handler; mark the arg `OPT_ARG_ENUM`/`validate: false` so the generic validator defers (§3) |
| YAML/PyYAML as a build dependency | never: generated C is committed; PyYAML is maintainer-time only (§1.3) |

---

## 10. Reference: source anchors

- `src/openvpn/options.c` — `add_option` (5609), `verify_permission` (5007), `VERIFY_PERMISSION`
  macro (4998), `no_more_than_n_args` (5061), `remove_option` (5099), `update_option` (5419),
  `usage_message` (122–790), `usage()` (4869), `check_route_option`/`check_dns_option`
  (5261/5310).
- `src/openvpn/options.h` — `OPT_P_*` masks (728–759), `OPT_P_U_*` (788–792), `MAX_PARMS` (51),
  `struct options` / `struct connection_entry` (the `set:` field catalog).
- `src/openvpn/options_util.{h,c}` — `valid_integer`, `positive_atoi`, `positive_atoll`,
  `atoi_warn`, `atoi_constrained`.
- `src/openvpn/options_parse.c` — `parse_line` (50) and the `char *p[MAX_PARMS + 1]` call sites.
- `contrib/cmake/parse-version.m4.py`, `contrib/cmake/git-version.py` — write-if-changed,
  stdlib-only generator templates and license header to mirror.
- `src/openvpn/Makefile.am`, `CMakeLists.txt`, root `Makefile.am` — build-wiring targets.
- `tests/unit_tests/openvpn/test_options_parse.c` — test pattern to extend.
- `doc/man-sections/*.rst` — long-form docs linked via `help.man_ref`.
