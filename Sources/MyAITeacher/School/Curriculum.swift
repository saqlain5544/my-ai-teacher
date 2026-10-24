import Foundation

/// The built-in programming curriculum: transferable concepts with outcomes per level and common misconceptions,
/// overlays for each language (syntax, errors, memory, toolchain, idioms, concurrency), and a catalog of courses from
/// school to research. Libraries and topics beyond it are proposed in lessons and validated by `CompetencyGraph`.
enum Curriculum {
    private static func c(_ id: String, _ title: String, _ prereqs: [String] = [], aliases: [String] = [], kind: Competency.Kind = .concept,
                          mis: [String] = [], school: String? = nil, college: String? = nil, university: String? = nil, research: String? = nil,
                          sources: [String] = []) -> Competency {
        var o: [Int: String] = [:]
        if let school { o[1] = school }
        if let college { o[2] = college }
        if let university { o[3] = university }
        if let research { o[4] = research }
        return Competency(id: id, title: title, kind: kind, prereqs: prereqs, aliases: aliases, misconceptions: mis, outcomes: o, sources: sources)
    }

    static let concepts: [Competency] = [
        // Fundamentals
        c("values-types", "Values and types", aliases: ["variables", "types", "data types"],
          mis: ["a variable is a box that holds the value (rather than a name bound to it)", "= means mathematical equality"],
          school: "trace assignments and say each variable's value and type after every line",
          college: "choose types for data and explain conversions and their failure cases",
          university: "explain value vs reference semantics and representation across languages"),
        c("control-flow", "Control flow", ["values-types"], aliases: ["conditionals", "loops", "if statements", "iteration"],
          mis: ["a loop's condition is checked continuously, not once per iteration", "else binds to the outer if"],
          school: "trace loops and branches by hand, predicting output",
          college: "write loops with correct bounds and invariants; spot off-by-one errors",
          university: "reason with loop invariants and termination arguments"),
        c("functions", "Functions", ["control-flow"], aliases: ["procedures", "parameters", "return values", "scope"],
          mis: ["printing a value is returning it", "a function changes its argument variable in the caller"],
          school: "call and write small functions; say what a call returns",
          college: "decompose a problem into functions with clear contracts; reason about scope",
          university: "design interfaces, pure vs effectful functions, higher-order functions"),
        c("collections", "Collections", ["functions"], aliases: ["arrays", "lists", "dictionaries", "maps", "sets"],
          mis: ["copying a list variable copies the list", "dictionary order is the insertion order in every language"],
          school: "index, loop over and update lists and maps",
          college: "pick a collection by its operations and costs",
          university: "explain the representations behind them and their complexity guarantees"),
        c("strings-text", "Strings and text", ["collections"], aliases: ["strings", "unicode", "text processing"],
          mis: ["one character is one byte", "string length counts what the reader sees"],
          school: "slice, search and build strings", college: "parse simple text formats; handle encodings deliberately",
          university: "reason about Unicode, normalisation and grapheme clusters"),
        c("io-files", "Input, output and files", ["functions"], aliases: ["file io", "reading files", "stdin"],
          school: "read input and print output; read and write a file", college: "handle errors and resources (closing, buffering) correctly"),
        c("problem-decomposition", "Problem decomposition", ["functions"], aliases: ["problem solving", "breaking down problems"],
          school: "split a task into steps before coding", college: "plan a multi-part program and test parts separately",
          university: "decompose under constraints and justify the boundaries"),
        c("recursion", "Recursion", ["functions"], aliases: ["recursive functions", "base case"],
          mis: ["the recursive call runs after the function returns", "every recursion needs an explicit stack"],
          school: "trace a recursive call tree for small inputs", college: "write recursive solutions with correct base cases; convert to iteration",
          university: "prove correctness by induction; reason about stack depth and tail calls"),
        c("errors-exceptions", "Error handling", ["functions"], aliases: ["exceptions", "error handling", "errors"],
          mis: ["catching every exception makes code safe", "an error code and an exception are interchangeable everywhere"],
          school: "read an error message and find the line", college: "choose between returning errors and raising; clean up on failure",
          university: "design error models (error unions, Result types, exceptions) and their trade-offs"),
        // Software construction
        c("debugging", "Debugging", ["control-flow"], aliases: ["debugger", "finding bugs"],
          mis: ["changing code at random until it works is debugging"],
          school: "use prints and the error message to find a bug", college: "form and test hypotheses; use a debugger and minimal reproductions",
          university: "debug concurrency, memory and performance problems systematically"),
        c("testing", "Testing", ["functions"], aliases: ["unit tests", "tests", "tdd"],
          mis: ["passing tests prove the code correct", "tests should mirror the implementation"],
          school: "run tests and read failures", college: "write unit tests for edge cases; test first",
          university: "design test strategies: properties, fuzzing, mutation testing, coverage limits"),
        c("version-control", "Version control", aliases: ["git", "commits", "branches"], kind: .toolchain,
          school: "commit, view history and revert", college: "branch, merge and resolve conflicts; write useful commits",
          university: "reason about history design, bisecting and collaboration workflows"),
        c("modules-interfaces", "Modules and interfaces", ["functions"], aliases: ["modules", "interfaces", "encapsulation", "abstraction"],
          college: "split code into modules with small interfaces", university: "design abstractions and APIs; manage coupling and change"),
        c("objects-types", "Objects and type design", ["modules-interfaces"], aliases: ["object oriented programming", "oop", "classes", "structs", "algebraic data types"],
          mis: ["inheritance is the main way to reuse code"],
          college: "model data with structs, classes or enums", university: "choose between inheritance, composition and sum types; make illegal states unrepresentable"),
        c("code-review", "Code review", ["testing"], aliases: ["reviewing code"],
          college: "review a change for correctness and clarity", university: "review for design, security and performance; give actionable critique"),
        c("design-patterns", "Software design", ["objects-types"], aliases: ["design patterns", "architecture", "software architecture"],
          college: "recognise common patterns in real code", university: "design and defend an architecture under requirements and constraints"),
        // Data structures and algorithms
        c("complexity", "Complexity analysis", ["control-flow", "functions"], aliases: ["big o", "time complexity", "asymptotic analysis"],
          mis: ["O(1) means fast", "big-O gives the exact running time"],
          school: "compare how loops grow with input size", college: "derive big-O for loops and recursion",
          university: "use amortised analysis and recurrences; relate asymptotics to real performance"),
        c("arrays-lists", "Arrays and linked lists", ["collections", "complexity"], aliases: ["linked lists", "dynamic arrays"],
          college: "implement a dynamic array and a linked list with their costs", university: "reason about cache behaviour and layout"),
        c("hash-tables", "Hash tables", ["arrays-lists"], aliases: ["hashing", "hash maps"],
          mis: ["hash tables are always O(1)"],
          college: "implement a hash table with collision handling", university: "analyse load factors, probing schemes and adversarial inputs"),
        c("trees", "Trees", ["recursion", "arrays-lists"], aliases: ["binary trees", "bst", "binary search trees", "heaps"],
          college: "implement a BST and traversals", university: "balanced trees, heaps and their invariants"),
        c("graphs", "Graphs", ["trees"], aliases: ["graph theory", "adjacency list"],
          college: "represent graphs and run BFS and DFS", university: "model problems as graphs; choose representations by density"),
        c("sorting-searching", "Sorting and searching", ["complexity", "arrays-lists"], aliases: ["sorting", "binary search", "quicksort", "merge sort"],
          school: "trace a simple sort", college: "implement and compare sorts; binary search without off-by-one errors",
          university: "lower bounds, stability, external sorting"),
        c("dynamic-programming", "Dynamic programming", ["recursion", "complexity"], aliases: ["dp", "memoization"],
          college: "memoise a recursive solution", university: "design DP formulations and prove their recurrence"),
        c("graph-algorithms", "Graph algorithms", ["graphs", "complexity"], aliases: ["shortest paths", "dijkstra", "minimum spanning tree", "topological sort"],
          college: "run Dijkstra and topological sort", university: "prove correctness and choose algorithms by constraints"),
        // Systems
        c("memory", "Memory and representation", ["values-types", "collections"], aliases: ["memory layout", "stack and heap", "bits and bytes"],
          mis: ["the stack and the heap are different kinds of memory hardware"],
          college: "explain stack vs heap and how values are laid out", university: "reason about alignment, padding, caches and allocators"),
        c("pointers", "Pointers and references", ["memory"], aliases: ["pointers", "references", "pointer arithmetic"],
          mis: ["a pointer is the value it points to", "a reference cannot dangle"],
          college: "use pointers safely and trace aliasing", university: "reason about aliasing, lifetimes and undefined behaviour"),
        c("ownership-lifetimes", "Ownership and lifetimes", ["pointers"], aliases: ["ownership", "borrowing", "lifetimes", "raii", "memory safety"],
          college: "say who frees each allocation", university: "design ownership models; explain borrow checking and RAII"),
        c("allocators", "Allocation strategies", ["memory", "pointers"], aliases: ["allocators", "arena", "malloc", "garbage collection"],
          university: "choose arenas, pools, GC or refcounting by workload; implement one"),
        c("os-processes", "Processes and the OS", ["memory"], aliases: ["operating systems", "processes", "system calls", "syscalls"],
          college: "explain processes, files and system calls", university: "reason about scheduling, virtual memory and IPC"),
        c("concurrency", "Concurrency", ["functions", "os-processes"], aliases: ["threads", "parallelism", "multithreading"],
          mis: ["concurrency and parallelism are the same", "a data race only matters on multi-core machines"],
          college: "start threads and protect shared state", university: "reason about races, deadlock and progress"),
        c("synchronization", "Synchronisation", ["concurrency"], aliases: ["locks", "mutex", "semaphores", "atomics"],
          university: "choose locks, atomics or message passing and prove the absence of races"),
        c("async-io", "Asynchronous programming", ["concurrency"], aliases: ["async await", "event loop", "futures", "promises"],
          college: "use async/await correctly", university: "explain event loops, cancellation and back-pressure"),
        c("memory-models", "Memory models", ["synchronization"], aliases: ["memory ordering", "happens before"],
          university: "explain happens-before and memory orderings", research: "analyse and verify concurrent algorithms under weak memory"),
        c("performance", "Performance engineering", ["complexity", "memory"], aliases: ["profiling", "optimization", "benchmarking"],
          college: "profile before optimising; benchmark fairly", university: "optimise for caches and allocation; read assembly where it matters"),
        // Languages and compilers
        c("lexing", "Lexical analysis", ["strings-text"], aliases: ["lexer", "tokenizer", "tokenization", "scanner"],
          college: "write a tokenizer for a small language", university: "use regular languages and automata; handle errors and positions"),
        c("grammars", "Grammars and context-free languages", ["lexing", "recursion"], aliases: ["context free grammar", "context-free grammars", "cfg", "bnf", "formal grammars"],
          mis: ["every grammar can be parsed by recursive descent", "ambiguity is a parser bug"],
          college: "write a BNF grammar for expressions", university: "transform grammars (left recursion, ambiguity, precedence); relate to the Chomsky hierarchy",
          research: "work with parsing theory: GLR, PEG, Earley and their limits"),
        c("parsing", "Parsing", ["grammars"], aliases: ["parser", "recursive descent", "precedence climbing", "pratt parsing", "ast"],
          college: "write a recursive-descent parser producing an AST", university: "handle precedence, associativity and error recovery; compare LL, LR and Pratt"),
        c("type-systems", "Type systems", ["objects-types", "parsing"], aliases: ["type checking", "type inference", "generics"],
          university: "implement a type checker; explain soundness and inference", research: "prove type safety; design type-system extensions"),
        c("semantics-interpreters", "Interpreters and semantics", ["parsing"], aliases: ["interpreter", "evaluation", "operational semantics"],
          college: "write a tree-walking interpreter", university: "define and implement semantics; closures and environments"),
        c("code-generation", "Code generation", ["semantics-interpreters", "memory"], aliases: ["compiler backend", "codegen", "ir", "intermediate representation"],
          university: "lower an AST to an IR and to machine code", research: "design optimisation passes and evaluate them"),
        // Data, networks, security
        c("databases", "Databases", ["collections"], aliases: ["sql", "relational databases", "queries"],
          college: "model data relationally and write SQL queries", university: "indexing, transactions and isolation levels"),
        c("networking", "Networking", ["os-processes"], aliases: ["tcp", "http", "sockets", "networks"],
          college: "write a client and server over TCP/HTTP", university: "reason about latency, failure and protocol design"),
        c("distributed-systems", "Distributed systems", ["networking", "concurrency"], aliases: ["consensus", "replication", "distributed computing"],
          university: "reason about partial failure, consistency and consensus", research: "evaluate distributed protocols formally and empirically"),
        c("security", "Security", ["memory", "networking"], aliases: ["secure coding", "vulnerabilities", "cryptography basics"],
          college: "recognise injection and unsafe input handling", university: "threat-model a system; explain memory-safety exploits and mitigations"),
        // Reading and research
        c("reading-source", "Reading real source code", ["modules-interfaces"], aliases: ["code reading", "reading source", "standard library source"],
          college: "navigate an unfamiliar codebase to answer a question", university: "explain a real implementation and its design decisions, citing file and line"),
        c("reading-papers", "Reading papers", ["reading-source"], aliases: ["research papers", "literature"], kind: .research,
          university: "summarise a paper's claim, method and evidence", research: "critique methods and situate a paper in its literature"),
        c("literature-review", "Literature review", ["reading-papers"], aliases: ["related work", "survey"], kind: .research,
          research: "map a field, find a gap and justify it"),
        c("research-questions", "Research questions", ["literature-review"], aliases: ["research question", "hypothesis"], kind: .research,
          research: "state a falsifiable question and its contribution"),
        c("experiment-design", "Experiment design", ["research-questions", "performance"], aliases: ["experiments", "evaluation methodology", "benchmarks design"], kind: .research,
          research: "design experiments with baselines, controls and threats to validity"),
        c("reproducibility", "Reproducibility", ["experiment-design", "version-control"], aliases: ["reproducible research", "artifact evaluation"], kind: .research,
          research: "package an artifact that others can reproduce"),
        c("academic-writing", "Academic writing", ["reading-papers"], aliases: ["writing papers", "technical writing"], kind: .research,
          university: "write a clear technical report", research: "write a paper: claim, method, evidence, related work"),
        c("peer-review", "Peer review", ["academic-writing", "code-review"], aliases: ["reviewing papers"], kind: .research,
          research: "review a paper fairly and specifically"),
        c("original-contribution", "Original contribution", ["reproducibility", "academic-writing"], aliases: ["thesis", "dissertation", "capstone research"], kind: .research,
          research: "produce and defend an original, reproducible result"),
    ]

    /// Languages with an overlay: what's specific to each, on top of the concepts it transfers from.
    static let languages: [(id: String, name: String, memory: Bool, sources: [String])] = [
        ("python", "Python", false, ["docs.python.org", "the CPython source"]),
        ("javascript", "JavaScript", false, ["the ECMAScript specification", "MDN"]),
        ("typescript", "TypeScript", false, ["the TypeScript handbook"]),
        ("c", "C", true, ["the C standard (N3220)", "K&R"]),
        ("cpp", "C++", true, ["cppreference", "the C++ standard"]),
        ("rust", "Rust", true, ["The Rust Programming Language", "the Rust reference", "rust-src"]),
        ("go", "Go", false, ["the Go specification", "GOROOT/src"]),
        ("zig", "Zig", true, ["the Zig language reference", "Zig's std source (zig env)"]),
        ("swift", "Swift", true, ["The Swift Programming Language", "the Swift source"]),
        ("java", "Java", false, ["the Java Language Specification"]),
        ("kotlin", "Kotlin", false, ["kotlinlang.org docs"]),
    ]

    static var overlays: [Competency] {
        languages.flatMap { l -> [Competency] in
            var out = [
                c("\(l.id).syntax", "\(l.name) syntax and basics", ["functions"], aliases: ["\(l.name) syntax", "\(l.name) basics", "learn \(l.name)"], kind: .language,
                  school: "write small \(l.name) programs with its syntax", college: "read and write idiomatic \(l.name) for multi-file programs", sources: l.sources),
                c("\(l.id).errors", "\(l.name) error handling", ["\(l.id).syntax", "errors-exceptions"], aliases: ["\(l.name) errors", "\(l.name) error handling"], kind: .language,
                  college: "handle failure the \(l.name) way", university: "design error handling for a \(l.name) library", sources: l.sources),
                c("\(l.id).toolchain", "\(l.name) toolchain", ["\(l.id).syntax"], aliases: ["\(l.name) build", "\(l.name) tooling", "\(l.name) toolchain"], kind: .toolchain,
                  school: "build, run and test a \(l.name) program", college: "manage dependencies, builds and debugging in \(l.name)", sources: l.sources),
                c("\(l.id).idioms", "Idiomatic \(l.name)", ["\(l.id).syntax", "\(l.id).errors"], aliases: ["idiomatic \(l.name)", "\(l.name) idioms", "\(l.name) standard library"], kind: .language,
                  college: "use \(l.name)'s standard library and idioms", university: "explain \(l.name)'s design choices from its source and specification", sources: l.sources),
                c("\(l.id).concurrency", "Concurrency in \(l.name)", ["\(l.id).syntax", "concurrency"], aliases: ["\(l.name) concurrency", "\(l.name) threads", "\(l.name) async"], kind: .language,
                  college: "use \(l.name)'s concurrency primitives correctly", university: "reason about \(l.name)'s concurrency model and memory guarantees", sources: l.sources),
            ]
            if l.memory {
                out.append(c("\(l.id).memory", "Memory in \(l.name)", ["\(l.id).syntax", "pointers"], aliases: ["\(l.name) memory", "\(l.name) pointers", "\(l.name) allocators", "\(l.name) ownership"], kind: .language,
                             college: "manage memory correctly in \(l.name)", university: "design allocation and ownership for a \(l.name) system", sources: l.sources))
            }
            return out.map { var x = $0; x.transfers = $0.prereqs.filter { !$0.hasPrefix(l.id + ".") }; return x }
        }
    }

    static let competencies: [Competency] = concepts + overlays

    static let baseCourses: [Course] = [
        Course(id: "PF101", title: "Programming Fundamentals", level: .school,
               summary: "Values, control flow, functions and debugging: reading, tracing and writing small programs.",
               competencies: ["values-types", "control-flow", "functions", "io-files", "debugging", "testing"], hours: 30, assessments: ["quiz", "lab", "unseen"]),
        Course(id: "PF102", title: "Data and Problem Solving", level: .school,
               summary: "Collections, strings, recursion and breaking a problem down.",
               competencies: ["collections", "strings-text", "recursion", "problem-decomposition", "errors-exceptions"], prereqs: ["PF101"], hours: 30, assessments: ["quiz", "lab", "project"]),
        Course(id: "SE210", title: "Software Construction", level: .college,
               summary: "Tests, debugging, modules, error handling, version control and review: programs that last.",
               competencies: ["testing", "debugging", "modules-interfaces", "errors-exceptions", "version-control", "code-review", "objects-types"], prereqs: ["PF102"], hours: 45, assessments: ["lab", "project", "review"]),
        Course(id: "CS201", title: "Data Structures", level: .college,
               summary: "Arrays, lists, hash tables, trees and graphs: implemented, measured and compared.",
               competencies: ["complexity", "arrays-lists", "hash-tables", "trees", "graphs"], prereqs: ["PF102"], hours: 45, assessments: ["lab", "unseen", "project"]),
        Course(id: "CS202", title: "Algorithms", level: .college,
               summary: "Sorting, searching, recursion, dynamic programming and graph algorithms, with analysis.",
               competencies: ["sorting-searching", "recursion", "dynamic-programming", "graph-algorithms", "complexity"], prereqs: ["CS201"], hours: 45, assessments: ["unseen", "exam", "lab"]),
        Course(id: "SYS301", title: "Systems Programming", level: .university,
               summary: "Memory, pointers, ownership, allocators, processes and performance, in a systems language.",
               competencies: ["memory", "pointers", "ownership-lifetimes", "allocators", "os-processes", "performance"], prereqs: ["CS201", "SE210"], hours: 60, assessments: ["lab", "project", "defence"]),
        Course(id: "SYS320", title: "Concurrency and Parallelism", level: .university,
               summary: "Threads, synchronisation, async I/O and memory models: correct concurrent programs.",
               competencies: ["concurrency", "synchronization", "async-io", "memory-models"], prereqs: ["SYS301"], hours: 45, assessments: ["lab", "project", "defence"]),
        Course(id: "PL330", title: "Compilers and Programming Languages", level: .university,
               summary: "Lexing, grammars and context-free languages, parsing, type systems, interpreters and code generation.",
               competencies: ["lexing", "grammars", "parsing", "semantics-interpreters", "type-systems", "code-generation"], prereqs: ["CS202", "SE210"], hours: 60, assessments: ["project", "unseen", "defence"]),
        Course(id: "NET340", title: "Networks and Distributed Systems", level: .university,
               summary: "Networking, protocols, partial failure, replication and consensus.",
               competencies: ["networking", "distributed-systems", "concurrency"], prereqs: ["SYS301"], hours: 45, assessments: ["project", "unseen", "defence"]),
        Course(id: "DB350", title: "Databases", level: .university,
               summary: "Relational modelling, SQL, indexing and transactions.",
               competencies: ["databases", "complexity"], prereqs: ["CS201"], hours: 40, assessments: ["lab", "project", "unseen"]),
        Course(id: "SEC360", title: "Software Security", level: .university,
               summary: "Threat modelling, memory-safety exploits and mitigations, secure design.",
               competencies: ["security", "pointers", "networking"], prereqs: ["SYS301"], hours: 40, assessments: ["lab", "review", "defence"]),
        Course(id: "SE380", title: "Software Design and Real Codebases", level: .university,
               summary: "Architecture, design under constraints, and reading real implementations from their source.",
               competencies: ["design-patterns", "reading-source", "code-review", "modules-interfaces"], prereqs: ["SE210"], hours: 40, assessments: ["project", "review", "defence"]),
        Course(id: "RES500", title: "Research Methods in Computing", level: .research,
               summary: "Reading papers, literature review, research questions, experiment design, reproducibility and writing.",
               competencies: ["reading-papers", "literature-review", "research-questions", "experiment-design", "reproducibility", "academic-writing"], prereqs: ["SE380"], hours: 60, assessments: ["paper", "review", "defence"]),
        Course(id: "RES600", title: "Research Apprenticeship", level: .research,
               summary: "An original, reproducible contribution under an advisor's critique, defended and peer reviewed. Human experts belong in the loop.",
               competencies: ["original-contribution", "peer-review", "reproducibility"], prereqs: ["RES500"], hours: 200, assessments: ["paper", "defence", "review"]),
    ]

    /// One course per language: its overlay at college level, for someone who knows the concepts elsewhere.
    static var languageCourses: [Course] {
        languages.map { l in
            Course(id: "LANG-\(l.id.uppercased())", title: "\(l.name) for Programmers", level: .college,
                   summary: "\(l.name)'s syntax, error handling, toolchain, idioms\(l.memory ? ", memory" : "") and concurrency, building on concepts you already hold.",
                   competencies: ["\(l.id).syntax", "\(l.id).errors", "\(l.id).toolchain", "\(l.id).idioms"] + (l.memory ? ["\(l.id).memory"] : []) + ["\(l.id).concurrency"],
                   prereqs: ["PF102"], hours: 30, assessments: ["lab", "project", "review"])
        }
    }

    static let courses: [Course] = baseCourses + languageCourses
}
