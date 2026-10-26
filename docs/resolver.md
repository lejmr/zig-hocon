# How substitutions resolve

`src/Value/Resolver.zig` and `src/Value/Resolver/stack.zig`, drawn in five views from the whole to the detail: from file to value, the walk over the tree, a key written more than once, one `${…}`, and a path with the cycles on it. Every node is named after the function that does it, so it can be found in the code. `L…` is a line in [spec/HOCON.md](../spec/HOCON.md), a three-digit number a case in [conformance/suite](../conformance/suite).

## Two rules almost everything follows from

- **A ref looks down.** When the top layer of a field is a `${…}`, or a concatenation with one, a path to that field sees the layers below it, as if the field had never been written from there up. `a = 1`, `a = ${a} x` gives `"1 x"` (L659, L684).
- **An object looks forward.** When the top layer is an object, a path into it sees it merged onto the layers below, along with what is being resolved right now, and resolves only the member it needs. `bar { foo = 42, baz = ${bar.foo} }` (L801, L815).

## 1 · From file to value

```mermaid
flowchart LR
  SRC[".conf file"] --> TOK["Tokenizer.next()<br/>src/Tokenizer.zig"]
  TOK --> AST["Ast.Parser.parse()<br/>src/Ast.zig"]
  AST --> BLD["Value.fromNode()<br/>src/Value/build.zig"]
  BLD --> INC["include: the file's tree in its place<br/>src/Include.zig"]
  INC --> BLD
  BLD --> MRG["mergeMembers / update<br/>src/Value/merge.zig"]
  MRG --> TREE["Value tree<br/>scalar · array · object<br/>ref = ${…}<br/>pending = concatenation<br/>stack = a key's layers"]
  TREE --> RES["Value.resolve()<br/>Resolver.zig"]
  RES -->|"env = map / none"| OUT1["values: JSON, a type T,<br/>Python, C"]
  RES -->|"env = keep"| OUT2["a tree with ${…} still waiting,<br/>stringify writes HOCON"]
```

- A key written once is a finished value; a key written more than once is a `.stack` of layers, and how they combine is for the resolver to say.
- Objects written one over the other merge while the tree is built. An object over a non-object gets the `hides` flag, so not even an include sees what it replaced.
- A ref built inside a list element carries `flags.anchor`: its path starts at that element, which no path from the root can name. `+=` and the substitutions of a file included there are built that way (L745, L1010).

## 2 · resolveValue: one walk over the tree

```mermaid
flowchart TD
  RV{"resolveValue(value)"}
  RV -->|scalar| S["returned as it is"]
  RV -->|array| A["each element: push elements,<br/>resolveValue; null, an undefined ${?…},<br/>is left out"]
  RV -->|object| O["each member:<br/>push visiting(&member)"]
  O --> WQ{"walking again and the<br/>member looks back?"}
  WQ -->|yes| WS["seen(member): the value<br/>its look-back sees"]
  WQ -->|no| RF["resolveField(&member)<br/>view 3"]
  RV -->|ref| RR["resolveRef(r, on_top = false)<br/>view 4"]
  RV -->|pending| RP["resolvePending(parts):<br/>each part through resolveValue,<br/>joined with update()"]
  RP --> RPN["text from a concatenation is a string,<br/>numbers as written (L366)"]
```

- `visiting` is the stack of places being resolved right now; a ref that reaches one of them closes a cycle.
- `elements` is the stack of list elements the walk is in. An object that is an element, or an object part of one, takes the element's entry: it is where an anchored path starts.
- How deep the value is (`depth`) and how long a chain of refs is (`chain`) are bounded by `Ast.max_depth`, beyond which it is `TooDeep`.

## 3 · resolveField and resolveStack: a key written more than once

```mermaid
flowchart TD
  RF["resolveField(place)"] --> KQ{"known already?<br/>kept · walked · vanished"}
  KQ -->|yes| KR["that value, or nothing"]
  KQ -->|no| KIND{"what the place holds"}
  KIND -->|"stack, ref, pending"| RS["resolveStack(layers)"]
  KIND -->|other| RV2["resolveValue"]
  RS --> TOP{"top layer"}
  TOP -->|"scalar / array"| HIDE["hides everything below<br/>(L776: hidden is never evaluated)"]
  TOP -->|object| OL["resolveObjectLayer<br/>FORWARD"]
  TOP -->|"ref / pending"| LB{"holds a ref?"}
  LB -->|"no: a list next to an object"| RV3["resolveValue(top)"]
  LB -->|yes| OAR{"shape ${x} #123; … #125; ?"}
  OAR -->|yes| ROAR["resolveObjectAfterRef:<br/>the object as a layer over ${x} (L398)"]
  OAR -->|no| PF["push Field(place, below)<br/>DOWN"]
  PF --> RRT["resolveRef(top, on_top = true)<br/>or resolveValue(top)"]
  RRT --> POP["pop Field"]
  POP --> AGQ{"field.again resolved?"}
  AGQ -->|yes| AGV["the value from the look-back:<br/>resolved once (L884)"]
  AGQ -->|no| RES{"result"}
  RES -->|"null"| UND["what is below the field"]
  RES -->|"non-object"| VAL["the value"]
  RES -->|"object, below mergeable"| MOB["resolveObjectLayer: merged<br/>onto below before either resolves"]
  OL --> OO["objectOnto: placeFor(merged object)<br/>push Field(object), push visiting,<br/>resolveValue(object)"]
  MOB --> OO
  HIDE --> STORE["place := result"]
  OO --> STORE
  AGV --> STORE
  UND --> STORE
  VAL --> STORE
  STORE --> MEMO["memoized by place: walked wins,<br/>nothing goes to vanished"]
```

- A `Field` on the `fields` stack says what a path that reaches the field meanwhile finds: the layers below it, or the merged object (`seen`, view 5).
- `mergeable`: an object on top merges with what is below only when that is an object or looks back. A concatenation with a list or text in it is a list, text or an error, never an object, so an object over it hides it, unevaluated (L384, L778).
- `vanished` remembers a field that resolved to nothing, and whether a cycle made it so: resolved again later, with the cycle over, it would find something, and the result would depend on which field went first.

## 4 · resolveRef: one ${…}

```mermaid
flowchart TD
  RR["resolveRef(r)"] --> OQ{"r is ${?…}?"}
  OQ -->|yes| RO["resolveOptional:<br/>push optionals(visiting depth)"]
  OQ -->|no| FR
  RO --> FR["followRef"]
  RO -.->|"SubstitutionCycle, breaking<br/>is this optional"| ON["null: a cycle is a missing value (L714)"]
  RO -.->|"closed below where it began:<br/>it led back to its own field"| ON2["null: refers to itself (L716)"]
  FR --> F1["follow(path with the include's scope)"]
  F1 --> FQ{"Found"}
  FQ -->|"absent / gone, from an include<br/>or anchored, not +="| F2["follow(path as written)"]
  F2 --> FQ2{"Found"}
  FQ -->|value| KQ{"env = keep<br/>and the value waits?"}
  FQ2 -->|value| KQ
  KQ -->|no| RET["the value"]
  KQ -->|yes| LATER["the ref stays in the tree<br/>(a self-ref: the layers below it<br/>over the path as written)"]
  FQ -->|waits| LATER
  FQ -->|absent| EQ{"anchored?"}
  FQ2 -->|absent| EQ
  EQ -->|"yes: nothing names the element"| MQ
  EQ -->|no| EV{"env"}
  EV -->|map| FE["fromEnv: the variable<br/>named like the path (L1540)"]
  EV -->|keep| LATER
  EV -->|none| MQ
  FE -->|found| RET
  FE -->|not set| MQ
  FQ -->|"gone: ${?…} on a cycle"| MQ
  FQ2 -->|gone| MQ
  MQ{"${?…}?"} -->|yes| NUL["null: no field, no element,<br/>empty in a concatenation (L632–639)"]
  MQ -->|no| UNR["error Unresolved"]
```

- `absent` means "not in the document", and only that goes on to the environment. `gone` means an optional on a cycle: the field is in the document, so no variable is read.
- A self-reference with nothing below it is `absent`, so it reads the variable of its own name (L767). An anchored path never does.
- **Rule R** (`closed`): an optional whose resolution leads back to the field it stands in, directly or through other fields (L673), is nonexistent (L716), whichever field is resolved first. `f = ${?a.t}x`, `a = ${?y}${?f}` gives `f = "x"`; `b = [${?a}]`, `a = [${?b}]` gives two empty lists (057).

## 5 · lookup, seen and resolveTarget: a path and the cycles on it

```mermaid
flowchart TD
  LK["lookup(path)<br/>from the root, or from the<br/>anchored list element"] --> STEP["next key of the path"]
  STEP --> SEEN{"seen(current, whole):<br/>is that field being resolved?"}
  SEEN -->|no| TA
  SEEN -->|"yes, an object layer"| OBJ["the merged object: FORWARD"]
  OBJ --> TA
  SEEN -->|"yes, busy resolving below"| CQ
  SEEN -->|"yes, nothing below,<br/>came round through another field"| AQ{"a later field looks back<br/>and again is not set?"}
  AQ -->|yes| AGN["field.again: resolved anew<br/>inside the look-back (035, 037)"]
  AQ -->|no| CQ
  SEEN -->|"yes, something below"| BEL["the layers below:<br/>resolveStack(below), DOWN (L659)"]
  BEL --> TA
  AGN --> TA
  TA{"throughAlias:<br/>the place is a = ${p}?"}
  TA -->|yes| TA2["lookup(p + rest of the path)<br/>only what is needed (L815, 038)"]
  TA -->|no| RQ{"ref / pending / stack?"}
  RQ -->|yes| RT["resolveTarget(current, whole = false)"]
  RQ -->|no| OBQ
  RT --> OBQ{"object?"}
  OBQ -->|no| ABS["absent"]
  OBQ -->|yes| MEM{"member there?"}
  MEM -->|no| ABS
  MEM -->|"yes, the path goes on"| STEP
  MEM -->|"yes, end of the path"| PLACE["the place: follow hands it to<br/>resolveTarget(whole = true)"]
  CQ{"${?…}?"} -->|yes| GONE["gone"]
  CQ -->|no| SC["SubstitutionCycle,<br/>markBreaking"]

  RT0["resolveTarget(target, whole)"] --> ELQ["elements: none for a path<br/>from the root, else up to its anchor"]
  ELQ --> VQ{"target in visiting,<br/>or whole and it holds one?"}
  VQ -->|no| PUSH["push visiting<br/>resolveField(target)"]
  VQ -->|yes| OQ2{"${?…}?"}
  OQ2 -->|yes| GONE2["null, closeAt(i)"]
  OQ2 -->|no| WAQ{"walkAgain: a list or object<br/>with a field on the cycle<br/>that looks back?"}
  WAQ -->|yes| WALK["walk it again, the field at<br/>its earlier value (L693, 007);<br/>outside the target: walked (L886)"]
  WAQ -->|no| BRK["markBreaking: the last ${?…}<br/>begun after the target (039)"]
  BRK --> SC2["SubstitutionCycle:<br/>up to resolveOptional,<br/>or out to the caller"]
```

- A cycle is found in two places: `seen`, when a path reaches a field being resolved, and `resolveTarget`, when a ref points at a place in `visiting`, or, at the end of its path (`whole`), at an object a place in `visiting` is in. A field that refers to the object it is in is the cycle of L688–691: `a { b = ${a} }`.
- It is broken in three ways: by looking down (`seen` with layers below the field), by resolving anew (`again`, `walkAgain`), or by an optional, which then finds nothing (`breaking`, `closed`, `resolveOptional`).
- A ref that reaches a field being resolved *came round* to it only through another field a ref led to (`targets`), or one resolved after it outside its value (`cameRound`); from inside the field's own value, an include there, it did not. An optional that reaches a field busy looking back at its layers, or an object holding one, is that look-back's business and finds nothing alone (`lookingBack`, `lookingBackIn`): `b.c += ${y}`, `b.c += 2`, `y = [1, ${?b}]` keeps `[[1], 2]`.
- What was resolved inside a look-back is that substitution's value (`walked`, `field.again`): a substitution is resolved once (L884, L886), so the result does not depend on which field went first.
