ENV += PDOC_ALLOW_EXEC=1

serve:
	$(ENV) poetry run pdoc -t themes/dark-mode --math checkdeps

docs:
	$(ENV) poetry run pdoc -t themes/dark-mode --math -o docs/ checkdeps

