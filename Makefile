SHELL := /bin/bash

PY_MODULE := sigstore

ALL_PY_SRCS := $(shell find $(PY_MODULE) -name '*.py') \
	$(shell find test -name '*.py')

# Optionally overriden by the user, if they're using a virtual environment manager.
VENV ?= env

# On Windows, venv scripts/shims are under `Scripts` instead of `bin`.
VENV_BIN := $(VENV)/bin
ifeq ($(OS),Windows_NT)
	VENV_BIN := $(VENV)/Scripts
endif

# Optionally overridden by the user in the `release` target.
BUMP_ARGS :=

# Optionally overridden by the user in the `test` target.
TESTS ?=

# Optionally overridden by the user/CI, to limit the installation to a specific
# subset of development dependencies.
SIGSTORE_EXTRA := dev

# If the user selects a specific test pattern to run, set `pytest` to fail fast
# and only run tests that match the pattern.
# Otherwise, run all tests and enable coverage assertions, since we expect
# complete test coverage.
ifneq ($(TESTS),)
	TEST_ARGS := -x -k $(TESTS) $(TEST_ARGS)
	COV_ARGS :=
else
	TEST_ARGS := $(TEST_ARGS)
# TODO: Reenable coverage testing
#	COV_ARGS := --fail-under 100
endif

ifneq ($(T),)
	T := $(T)
else
	T := test/unit
endif

.PHONY: all
all:
	@echo "Run my targets individually!"

$(VENV)/pyvenv.cfg: pyproject.toml
	# Create our Python 3 virtual environment
	python3 -m venv $(VENV)
	$(VENV_BIN)/python -m pip install --upgrade pip
	$(VENV_BIN)/python -m pip install -e .[$(SIGSTORE_EXTRA)]

.PHONY: dev
dev: $(VENV)/pyvenv.cfg

.PHONY: run
run: $(VENV)/pyvenv.cfg
	@. $(VENV_BIN)/activate && sigstore $(ARGS)

.PHONY: lint
lint: $(VENV)/pyvenv.cfg
	. $(VENV_BIN)/activate && \
		black --check $(ALL_PY_SRCS) && \
		isort --check $(ALL_PY_SRCS) && \
		ruff $(ALL_PY_SRCS) && \
		mypy $(PY_MODULE) && \
		bandit -c pyproject.toml -r $(PY_MODULE) && \
		interrogate --fail-under 100 -c pyproject.toml $(PY_MODULE)

.PHONY: reformat
reformat: $(VENV)/pyvenv.cfg
	. $(VENV_BIN)/activate && \
		ruff --fix $(ALL_PY_SRCS) && \
		black $(ALL_PY_SRCS) && \
		isort $(ALL_PY_SRCS)

.PHONY: test
test: $(VENV)/pyvenv.cfg
	. $(VENV_BIN)/activate && \
		pytest --cov=$(PY_MODULE) $(T) $(TEST_ARGS) && \
		python -m coverage report -m $(COV_ARGS)

.PHONY: doc
doc: $(VENV)/pyvenv.cfg
	. $(VENV_BIN)/activate && \
		pdoc --output-directory html $(PY_MODULE)

.PHONY: package
package: $(VENV)/pyvenv.cfg
	. $(VENV_BIN)/activate && \
		python3 -m build

.PHONY: release
release: $(VENV)/pyvenv.cfg
	@. $(VENV_BIN)/activate && \
		NEXT_VERSION=$$(bump $(BUMP_ARGS)) && \
		git add $(PY_MODULE)/_version.py && git diff --quiet --exit-code && \
		git commit -m "version: v$${NEXT_VERSION}" && \
		git tag v$${NEXT_VERSION} && \
		echo "RUN ME MANUALLY: git push origin main && git push origin v$${NEXT_VERSION}"

.PHONY: check-readme
check-readme:
	# sigstore --help
	@diff \
	  <( \
	    awk '/@begin-sigstore-help@/{f=1;next} /@end-sigstore-help@/{f=0} f' \
	      < README.md | sed '1d;$$d' \
	  ) \
	  <( \
	    $(MAKE) -s run ARGS="--help" \
	  )

	# sigstore sign --help
	@diff \
	  <( \
	    awk '/@begin-sigstore-sign-help@/{f=1;next} /@end-sigstore-sign-help@/{f=0} f' \
	      < README.md | sed '1d;$$d' \
	  ) \
	  <( \
	    $(MAKE) -s run ARGS="sign --help" \
	  )

	# sigstore verify identity --help
	@diff \
	  <( \
	    awk '/@begin-sigstore-verify-identity-help@/{f=1;next} /@end-sigstore-verify-identity-help@/{f=0} f' \
	      < README.md | sed '1d;$$d' \
	  ) \
	  <( \
	    $(MAKE) -s run ARGS="verify identity --help" \
	  )

	# sigstore verify github --help
	@diff \
	  <( \
	    awk '/@begin-sigstore-verify-github-help@/{f=1;next} /@end-sigstore-verify-github-help@/{f=0} f' \
	      < README.md | sed '1d;$$d' \
	  ) \
	  <( \
	    $(MAKE) -s run ARGS="verify github --help" \
	  )


.PHONY: edit
edit:
	$(EDITOR) $(ALL_PY_SRCS)
