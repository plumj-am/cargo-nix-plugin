fn main() {}

#[cfg(test)]
mod tests {
    #[test]
    fn must_not_run() {
        panic!("test = false bin harness was built");
    }
}
