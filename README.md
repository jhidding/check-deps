# A dependency checker in Async Python
[![website](https://github.com/jhidding/check-deps/actions/workflows/main.yml/badge.svg)](https://github.com/jhidding/check-deps/actions/workflows/main.yml)
[![Entangled badge](https://img.shields.io/badge/entangled-Use%20the%20source!-%2300aeff)](https://entangled.github.io/)

Sometimes, when you have a project that uses many components there are no easy ways to systematically check if dependencies are installed. If you stick to a single programming language, this problem is better handled by a package manager. When you step outside the bounds of a single language however, there is no easy to use tool. Maybe you need some UNIX tools to be present along with utilities from Python and some scripts that run on top of Node.

The goal of this script is to check software dependencies for you. If you have some complicated setup which requires a combination of executables, libraries for different languages etc., this script can check if those are in order.

You specify the dependencies in a `dependencies.ini` file, then this script checks them. You only need Python installed, nothing else for this script to work. [You simply ship this script with your distribution.](https://github.com/jhidding/check-deps/blob/main/check-deps)

# Tutorial
Suppose your project needs a specific version of GNU Awk. According to the GNU guidelines for writing command-line applications, every program should support the `--version` flag. If we run `awk --version`, what do we get?

``` {.bash .eval}
awk --version
```

That's a lot of information, but all we need is a version number. From all that output we need to extract a version number, which is best done by regex. Let's ask for an impossible version:

``` {.ini file=example/first/dependencies.ini}
[awk]
require = >=6
get_version = awk --version
pattern = GNU Awk (.*), API: .*
suggestion_text = This should be available from your package manager.
```

Now run `check-deps`

``` {.bash .eval}
cd example/first; ../../check-deps
```

The output of `check-deps`, out of necessity, is the most spectacular when a problem is detected. For a second example let's try one that succeeds. We add GNU Make to our dependencies.

``` {.ini file=example/second/dependencies.ini}
[awk]
require = >=5
get_version = awk --version
pattern = GNU Awk (.*), API: .*
suggestion_text = This should be available from your package manager.

[make]
require = >=4
get_version = make --version
pattern = GNU Make (.*)
suggestion_text = This should be available from your package manager.
```

``` {.bash .eval}
cd example/second; ../../check-deps
```

## Dependencies
Now for some Python packages. First we need to ensure that the correct version of Python in installed. This follows the pattern that we saw before.

``` {.ini file=example/depends/dependencies.ini #example-depends}
[python3]
require = >=3.12
get_version = python3 --version
pattern = Python (.*)
suggestion_text = This is a problem. The easiest is probably to install Anaconda from https://www.anaconda.com/.
```

To check the version of an installed package we may use `pip`.

``` {.ini #example-depends}
[numpy]
require = >=1.0
get_version = pip show numpy | grep "Version:"
pattern = Version: (.*)
suggestion_text = This is a Python package that can be installed through pip.
suggestion = pip install numpy
depends = python3
```

Now `check-deps` knows to check for Python before checking for `numpy`.

``` {.bash .eval}
cd example/depends; ../../check-deps
```

Once we ask for one Python package, it is not so strange to ask for more. In that case it can be advantageous to use a template.

## Templates
Because we may need many Python packages, it is possible to define a template. The template defines all the fields that we would expect from a normal entry, but uses Python formating syntax to define some wildcards. These wildcards are interpolated using values given at instantiation of a template. In this case we only ask for `name`, but this key is not fixed. Then the output of the template is merged with the specifics. If keys clash, the instance overrules the template's defaults.

``` {.ini file=example/template/dependencies.ini}
[template:pip]
get_version = pip show {name} | grep "Version:"
pattern = Version: (.*)
suggestion_text = This is a Python package that can be installed through pip.
suggestion = pip install {name}
depends = python3

[python3]
require = >=3.8
get_version = python3 --version
pattern = Python (.*)
suggestion_text = This is a problem. The easiest is probably to install Anaconda from https://www.anaconda.com/.

[numpy]
require = >=1.0
template = pip
```

``` {.bash .eval}
cd example/template; ../../check-deps
```

That covers all the features of this script. The rest of this README is the actual implementation of `check-deps`.

# Implementation
Because this script needs to work stand-alone, that means that some of the functionality here would be much easier implemented using other packages, however I'm limited to what a standard Python install has to offer.

I'll start with a bit of version logic, and then show how this script runs the checks in parallel using `asyncio`.

``` {.python #boilerplate}
assert sys.version_info[0] == 3, "This script only works with Python 3."

class ConfigError(Exception):
    pass

T = TypeVar("T")
```

``` {.python file=check-deps header=1}
#!/usr/bin/env python3
from __future__ import annotations

<<imports>>
<<boilerplate>>

<<relation>>
<<version>>
<<version-constraint>>
<<parsing>>
<<running>>
```

## Imports
We use a lot of things that should be in the standard library, chiefly typing and dataclasses. Then, some `textwrap` and `redirect_stdout` for fancy output.

``` {.python #imports}
import sys
import configparser
from dataclasses import dataclass, field
from typing import Optional, List, Mapping, Tuple, Callable, TypeVar
from enum import Enum
import asyncio
import re
from contextlib import contextmanager, redirect_stdout
import textwrap
import io
```

## Versions

It is common to label software versions with series of ascending numbers. A often recommended pattern is that of *major*, *minor*, *patch* semantic versioning, where a version contains three numbers separated by dots, sometimes post-fixed with addenda for alpha, beta or release candidates. There are notable exceptions, chief among them $\TeX$, which has version numbers converging to the digits of $\pi$.

We would like to express version constraints using comparison operators along with the murky semantics of version numbers found in the wild. So we have the following relations in an enum:

``` {.python #relation}
class Relation(Enum):
    """Encodes ordinal relations among versions. Currently six operators are
    supported: `>=`, `<=`, `<`, `>`, `==`, `!=`.""" 
    GE = 1
    LE = 2
    LT = 3
    GT = 4
    EQ = 5
    NE = 6

    def __str__(self):
        return {
            Relation.GE: ">=",
            Relation.LE: "<=",
            Relation.LT: "<",
            Relation.GT: ">",
            Relation.EQ: "==",
            Relation.NE: "!="}[self]
```

I'm going out on a limb and say that versions consist of a `tuple` of `int`, optionally with a suffix that can be stored in a `str`. We need to define an ordering on this system:

``` {.python #version}
@dataclass
class Version:
    """Stores a version in the form of a tuple of ints and an optional string extension.
    This class supports (in)equality operators listed in `Relation`."""
    number: tuple[int, ...]
    extra: Optional[str]

    <<version-methods>>
```
<details>
<summary>Implementation of `Version` operators</summary>
``` {.python #version-methods}
def __lt__(self, other):
    for n, m in zip(self.number, other.number):
        if n < m:
            return True
        elif n > m:
            return False
    return False

def __gt__(self, other):
    return other < self

def __le__(self, other):
    for n, m in zip(self.number, other.number):
        if n < m:
            return True
        elif n > m:
            return False
    return True

def __ge__(self, other):
    return other <= self

def __eq__(self, other):
    for n, m in zip(self.number, other.number):
        if n != m:
            return False
        return True

def __ne__(self, other):
    return not self == other

def __str__(self):
    return ".".join(map(str, self.number)) + (self.extra or "")
```
</details>

A combination of a `Version` with a `Relation` form a `VersionConstraint`. Such a constraint can be called with another `Version` which should give a `bool`.

``` {.python #version-constraint}
@dataclass
class VersionConstraint:
    """A VersionConstraint is a product of a `Version` and a `Relation`."""
    version: Version
    relation: Relation

    def __call__(self, other: Version) -> bool:
        method = f"__{self.relation.name}__".lower()
        return getattr(other, method)(self.version)

    def __str__(self):
        return f"{self.relation}{self.version}"
```

Now, we also need to be able to read a version constraint from input.
Each parser takes a `str` and returns a tuple of `(value, str)`, where the second part of the tuple is the text that is not yet parsed.

<details><summary>Parsing version constraints</summary>
``` {.python #parsing}
def split_at(split_chars: str, x: str) -> Tuple[str, str]:
    """Tries to split at character `x`. Returns a 2-tuple of the string
    before and after the given separator."""
    a = x.split(split_chars, maxsplit=1)
    if len(a) == 2:
        return a[0], a[1]
    else:
        return a[0], ""


def parse_split_f(split_chars: str, f: Callable[[str], T], x: str) \
        -> Tuple[T, str]:
    """Given a string, splits at given character `x` and passes the left value
    through a function (probably a parser). The second half of the return tuple is the
    remainder of the string."""
    item, x = split_at(split_chars, x)
    val = f(item)
    return val, x


def parse_version(x: str) -> Tuple[Version, str]:
    """Parse a given string to a `Version`. A sequence of dot `.` separated integers
    is put into the numerical version component, while the remaining text ends up in
    the `extra` component."""
    _x = x
    number = []
    extra = None

    while True:
        try:
            n, _x = parse_split_f(".", int, _x)
            number.append(n)
        except ValueError:
            if len(x) > 0:
                m = re.match("([0-9]*)(.*)", _x)
                if lastn := m and m.group(1):
                    number.append(int(lastn))
                if suff := m and m.group(2):
                    extra = suff or None
                else:
                    extra = _x
            break

    if not number:
        raise ConfigError(f"A version needs a numeric component, got: {x}")

    return Version(tuple(number), extra), _x


def parse_relation(x: str) -> Tuple[Relation, str]:
    """Parses the operator of the version constraint."""
    op_map = {
        "<=": Relation.LE,
        ">=": Relation.GE,
        "<": Relation.LT,
        ">": Relation.GT,
        "==": Relation.EQ,
        "!=": Relation.NE}
    for sym, op in op_map.items():
        if x.startswith(sym):
            return (op, x[len(sym):])
    raise ConfigError(f"Not a comparison operator: {x}")


def parse_version_constraint(x: str) -> Tuple[VersionConstraint, str]:
    relation, x = parse_relation(x)
    version, x = parse_version(x)
    return VersionConstraint(version, relation), x
```
</details>

## Running

Some check may need to be preceded by another check. Say if we want to see if we have some Python module installed, first we need to see if the correct Python version is here, then if `pip` is actually installed, then if we can see the module. If we have many such modules, how do we make sure that we check for Python and `pip` only once? One way is to plan everything in advance, then run the workflow. That's nice, but adds a lot of complication on top of what we can get out of the box with `asyncio`. Another way is to cache results, and then when we need the result a second time, we used the cached value.

``` {.python #running}
def async_cache(f):
    """Caches results from the `async` function `f`. This assumes `f` is a
    member of a class, where we have `_lock`, `_result` and `_done` members
    available."""
    async def g(self, *args, **kwargs):
        async with self._lock:
            if self._done:
                return self._result
            self._result = await f(self, *args, **kwargs)
            self._done = True
            return self._result
    return g
```

### Result
The result of a version check is stored in `Result`.

``` {.python #running}
@dataclass
class Result:
    test: VersionTest
    success: bool
    failure_text: Optional[str] = None
    found_version: Optional[Version] = None

    def __bool__(self):
        return self.success
```

### Job
The logistics for each job checking a version are stored in `VersionTest`. This is basically a giant closure wrapped in `async_cache`. 

The `run` method takes an argument `recurse`. This is used to call dependencies of the current version test.

``` {.python #running}
@dataclass
class VersionTest:
    name: str
    require: VersionConstraint
    get_version: str
    platform: Optional[str] = None
    pattern: Optional[str] = None
    suggestion_text: Optional[str] = None
    suggestion: Optional[str] = None
    depends: List[str] = field(default_factory=list)
    template: Optional[str] = None

    _lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    _done: bool = False

    def print_formatted(self, msg):
        prefix = f"{self.name} {self.require}"
        print(f"{prefix:25}: {msg}")

    def print_not_found(self):
        self.print_formatted("not found")

    @async_cache
    async def run(self, recurse):
        for dep in self.depends:
            if not await recurse(dep):
                return Result(self, False,
                              failure_text=f"Failed dependency: {dep}")

        proc = await asyncio.create_subprocess_shell(
            self.get_version,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE)
        (stdout, stderr) = await proc.communicate()
        if proc.returncode != 0:
            self.print_not_found()
            return Result(
                self,
                success=False,
                failure_text=f"{stderr.decode().strip()}")
        try:
            if self.pattern is not None:
                m = re.match(self.pattern, stdout.decode())
                if m is not None:
                    out, _ = parse_version(m.group(1).strip())
                else:
                    self.print_not_found()
                    msg = f"No regex match on pattern '{self.pattern}'"
                    return Result(self, False, failure_text=msg)
            else:
                out, _ = parse_version(stdout.decode().strip())
        except ConfigError as e:
            return Result(self, False, failure_text=str(e))

        if self.require(out):
            self.print_formatted(f"{str(out):10} Ok")
            return Result(self, True)
        else:
            self.print_formatted(f"{str(out):10} Fail")
            return Result(self, False, failure_text="Too old.",
                          found_version=out)
```

### Parsing input

``` {.python #running}
def parse_config(name: str, config: Mapping[str, str], templates):
    if "template" in config:
        _config = {}
        for k, v in templates[config["template"]].items():
            if isinstance(v, str):
                _config[k] = v.format(name=name)
            else:
                _config[k] = v
        _config.update(config)
    else:
        _config = dict(config)

    _deps = map(str.strip, _config.get("depends", "").split(","))
    deps = list(filter(lambda x: x != "", _deps))

    assert "require" in _config, "Every item needs a `require` field"
    assert "get_version" in _config, "Every item needs a `get_version` field"

    require, _ = parse_version_constraint(_config["require"])

    return VersionTest(
        name=name,
        require=require,
        get_version=_config["get_version"],
        platform=_config.get("platform", None),
        pattern=_config.get("pattern", None),
        suggestion_text=_config.get("suggestion_text", None),
        suggestion=_config.get("suggestion", None),
        depends=deps,
        template=_config.get("template", None))
```

### Indentation
It looks nice to indent some output. This captures `stdout` and forwards it by printing each line with a given prefix.

``` {.python #running}
@contextmanager
def indent(prefix: str):
    f = io.StringIO()
    with redirect_stdout(f):
        yield
    output = f.getvalue()
    print(textwrap.indent(output, prefix), end="")
```


### Main

``` {.python #running}
async def main():
    config = configparser.ConfigParser()
    config.read("dependencies.ini")

    templates = {
        name[9:]: config[name]
        for name in config if name.startswith("template:")
    }

    try:
        tests = {
            name: parse_config(name, config[name], templates)
            for name in config if ":" not in name and name != "DEFAULT"
        }
    except (AssertionError, ConfigError) as e:
        print("Configuration error:", e)
        sys.exit(1)

    async def test_version(name: str):
        assert name in tests, f"unknown dependency {name}"
        x = await tests[name].run(test_version)
        return x

    result = await asyncio.gather(*(test_version(k) for k in tests))
    if all(r.success for r in result):
        print("Success")
        sys.exit(0)
    else:
        print("Failure")
        with indent("  |  "):
            for r in (r for r in result if not r.success):
                if r.failure_text:
                    print(f"{r.test.name}: {r.failure_text}")
                if r.found_version:
                    print(f"    found version {r.found_version}")
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
```

# Literate Programming
This script is composed from the code blocks in this README using [Entangled](https://entangled.github.io). To generate the HTML renedered documentation, I used [Pdoc](https://pdoc.dev/) in conjunction with some Awk scripts.

Note, all output from the shell scripts in the tutorial are expanded by Awk in CI. That means that the tutorial doubles up for integration test as well.

``` {.python file=checkdeps/__init__.py}
from __future__ import annotations

import subprocess
proc_eval = subprocess.run(
    ["awk", "-f", "eval_shell_pass.awk"],
    input=open("README.md", "rb").read(), capture_output=True)
proc_label = subprocess.run(
    ["awk", "-f", "noweb_label_pass.awk"],
    input=proc_eval.stdout, capture_output=True)
__doc__ = proc_label.stdout.decode()

<<imports>>
<<boilerplate>>

<<relation>>
<<version>>
<<version-constraint>>
<<parsing>>
<<running>>
```

# API Documentation
While this script strictly speaking is in no need for API docs, here they are anyway.

