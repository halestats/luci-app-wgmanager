.PHONY: all test

all:
	python3 scripts/build_ipk.py

# Supply the target-compatible interpreter; see docs/TESTING.md.
test:
	$(UCODE) tests/core_test.uc
