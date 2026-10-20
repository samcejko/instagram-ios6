"""Execute the production chunk-size arithmetic as portable C on the CI host."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "src/Net/SHHTTPRequest.m").read_text()
start = source.index("            unsigned long long size = 0;", source.index("// Parse every digit"))
end = source.index("            if (size == 0)", start)
body = source[start:end]
body = body.replace("self.bodyError = YES; return YES;", "return 0;")
body = body.replace("NSUInteger digitCount = [hex lengthOfBytesUsingEncoding:NSUTF8StringEncoding];", "")
body = body.replace("NSUInteger", "size_t")
program = """
#include <stddef.h>
#include <limits.h>
#include <assert.h>
#include <string.h>
static int parse(const char *digits, size_t digitCount, unsigned long long *out) {
""" + body + """
    *out = size;
    return 1;
}
int main(void) {
    unsigned long long result = 0;
    assert(parse("0", 1, &result) && result == 0);
    assert(parse("aF", 2, &result) && result == 175);
    assert(parse("FFFFFFFF", 8, &result) && result == 4294967295ULL);
    assert(parse("7fffffffffffffff", 16, &result) && result == LLONG_MAX);
    const char *bad[] = {"", "-1", "+1", " 1", "1 ", "0x10", "g", "1z",
                        "8000000000000000", "ffffffffffffffff", "10000000000000000"};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
        assert(!parse(bad[i], strlen(bad[i]), &result));
    assert(!parse(NULL, 0, &result));
    assert(!parse("1\\0f", 3, &result));
    return 0;
}
"""
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp)
    (path / "test.c").write_text(program)
    subprocess.run(["cc", "-std=c99", "-Wall", "-Wextra", "-Werror",
                    str(path / "test.c"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
print("Production HTTP chunk-size parser: boundary and malformed-input checks passed")
