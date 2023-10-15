fn main() {
    cc::Build::new()
        .cpp(true)
        .file("cpp_exception/exception.cpp")
        .compile("cpp_exception");
}
