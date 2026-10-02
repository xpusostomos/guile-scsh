test:
	guile -L . -L .. scsh-test

# structured-editor simulator: drives the real callbacks with readline/FFI stubbed
# out, so it needs no tty and can run anywhere
editor:
	cd .. && env SCHI_REPO="$$(pwd)" SCSH_EDITOR_NO_LOOP=1 GUILE_AUTO_COMPILE=0 guile -q -L . test-suite/scheme-shell-test.scm

# the structure editor: tree model, ops, renderer, and the REPL loop
# (all pure / scripted -- no terminal needed)
engine:
	cd .. && guile -q -L . test-suite/editor-engine-test.scm
	cd .. && guile -q -L . test-suite/editor-repl-test.scm
	cd .. && guile -q -L . test-suite/editor-scsh-test.scm
	cd .. && guile -q -L . test-suite/editor-job-test.scm
	cd .. && guile -q -L . test-suite/editor-history-test.scm
	cd .. && guile -q -L . test-suite/editor-properties-test.scm
