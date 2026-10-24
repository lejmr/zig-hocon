// adapter: puppetlabs/cpp-hocon — run.sh contract (path in, compact JSON out, non-zero on rejection)
#include <hocon/config.hpp>
#include <hocon/config_render_options.hpp>
#include <hocon/config_object.hpp>
#include <iostream>
#include <cstring>
int main(int argc, char** argv) {
    if (argc > 1 && std::strcmp(argv[1], "--version") == 0) { std::cout << "cpp-hocon 4981ed4\n"; return 0; }
    try {
        auto c = hocon::config::parse_file_any_syntax(argv[1])->resolve();
        std::cout << c->root()->render(hocon::config_render_options(false, false, false, true)) << "\n";
        return 0;
    } catch (std::exception const& e) {
        std::cerr << "ERROR " << e.what() << "\n"; return 1;
    }
}
