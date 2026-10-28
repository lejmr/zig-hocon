"""A tree is read only: copy and deepcopy give the tree itself, as code from
pyhocon copies its config before it changes it."""

import copy

from zig_hocon import ConfigFactory


def test_a_tree_copied_is_itself():
    conf = ConfigFactory.parse_string("db { host = burrow, port = 5432 }", env=None)
    for copied in (
        copy.copy(conf),
        copy.deepcopy(conf),
        copy.deepcopy({"conf": conf})["conf"],
    ):
        assert copied is conf
    assert copy.deepcopy(conf.get_config("db")).get_int("port") == 5432
