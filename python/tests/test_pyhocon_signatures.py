"""zig_hocon.pyhocon has pyhocon's interface: every public name of the
installed pyhocon, in the same module, a function or method with pyhocon's
parameters (names, kinds, defaults) and at most more of its own after them
that have a default, a class with pyhocon's bases among its own. The modules
and names are read from pyhocon when the tests are collected, so a pyhocon
release with a new module, name or argument is a new case that fails, and so
is a change here that drops one. Where they differ by design the case is an
xfail that says why, strict, so a difference that goes away shows."""

import importlib
import inspect
import pkgutil

import pytest

pyhocon = pytest.importorskip("pyhocon")

MODULES = [""] + ["." + m.name for m in pkgutil.iter_modules(pyhocon.__path__)]

# pyhocon's parser objects, made while it parses; here a placeholder of the
# name, for code that imports one or checks a value against it
_PARSER_OBJECT = "a parser object pyhocon makes while it parses; a placeholder here"

_GRAMMAR = "pyhocon's pyparsing grammar; libhocon reads the document"

# The differences by design: a name, `Class.member`, or a class for all its
# members.
DIFFERS = {
    "ConfigValues.*": _PARSER_OBJECT,
    "ConfigSubstitution.*": _PARSER_OBJECT,
    "ConfigQuotedString.*": _PARSER_OBJECT,
    "ConfigInclude.*": _PARSER_OBJECT,
    "ConfigList.__init__": "a plain list subclass, constructed as list is",
    "ConfigTree.resolve": "not there yet, MIGRATING.md",
    "ConfigParser.unresolve_substitutions_to_value": "pyhocon's STR_SUBSTITUTION, which is not supported, MIGRATING.md",
    "ConfigException.__init__": "zig_hocon's exceptions: (message, name, file, line, column, source_line), not (message, ex)",
    "get_period_expr": _GRAMMAR,
    "convert_period": _GRAMMAR,
    "fixed_get_attr": _GRAMMAR,
    "ListParser": _GRAMMAR,
    "ListParser.*": _GRAMMAR,
    "ConcatenatedValueParser": _GRAMMAR,
    "ConcatenatedValueParser.*": _GRAMMAR,
    "ConfigTreeParser": _GRAMMAR,
    "ConfigTreeParser.*": _GRAMMAR,
    "find_package_dirs": "pyhocon's include package(…), which the spec does not have",
}


def _ours(module):
    return importlib.import_module("zig_hocon.pyhocon" + module)


def _theirs(module):
    return importlib.import_module("pyhocon" + module)


def _public(module):
    """pyhocon's public names in ``module``: (case id, name, its object)."""
    short = module.lstrip(".") or "pyhocon"
    for name, obj in vars(_theirs(module)).items():
        if not name.startswith("_") and getattr(obj, "__module__", "").split(".")[0] == "pyhocon":
            yield f"{short}.{name}", name, obj


def _cases():
    seen = set()
    for module in MODULES:
        for case, name, obj in _public(module):
            yield case, module, name, None, DIFFERS.get(name)
            if inspect.isclass(obj) and obj not in seen:
                seen.add(obj)
                for member, value in vars(obj).items():
                    if callable(value) or isinstance(value, (classmethod, staticmethod)):
                        if not member.startswith("_") or member == "__init__":
                            why = DIFFERS.get(f"{name}.{member}") or DIFFERS.get(f"{name}.*")
                            yield f"{name}.{member}", module, name, member, why


def _param(case, module, name, member, why):
    marks = [pytest.mark.xfail(strict=True, reason=why)] if why else []
    return pytest.param(module, name, member, id=case, marks=marks)


def _signature(f):
    """The parameters of ``f``: name, kind and default, a class default by
    its name (pyhocon's UndefinedKey is ours by name, not by identity), and
    ``self`` of any kind, as no one passes it by name: a builtin's is
    positional-only. None for a builtin that tells none: OrderedDict.items
    before CPython 3.13."""
    try:
        signature = inspect.signature(f)
    except ValueError:
        return None
    params = []
    for p in signature.parameters.values():
        default = p.default
        if default is not p.empty:
            default = default.__name__ if inspect.isclass(default) else repr(default)
        params.append((p.name, "POSITIONAL_OR_KEYWORD" if p.name == "self" else p.kind.name, default))
    return params


def _builtin_base(module, name):
    """The builtin base of our class ``name``, where a member comes from."""
    return next(c for c in getattr(_ours(module), name).__mro__ if c.__module__ in ("builtins", "collections"))


def _mro(cls):
    return [c.__name__ for c in cls.__mro__ if c is not object]


@pytest.mark.parametrize("module, name, member", [_param(*c) for c in _cases()])
def test_same_interface_as_pyhocon(module, name, member):
    theirs, ours = getattr(_theirs(module), name), getattr(_ours(module), name, None)
    assert ours is not None, f"no {name} in zig_hocon.pyhocon{module}"
    if member is not None:
        theirs, ours = getattr(theirs, member), getattr(ours, member, None)
        assert ours is not None, f"no {name}.{member}"
    if inspect.isclass(theirs):
        assert set(_mro(theirs)) <= set(_mro(ours))
    elif callable(theirs):
        mine, pyhocons = _signature(ours), _signature(theirs)
        if mine is None:
            # OrderedDict's own, which pyhocon overrides for Python 2's sake
            assert ours is getattr(_builtin_base(module, name), member, None)
            return
        assert mine[: len(pyhocons)] == pyhocons
        assert all(default is not None for _, _, default in mine[len(pyhocons) :]), "a parameter pyhocon has not, with no default"
