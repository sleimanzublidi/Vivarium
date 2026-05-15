.PHONY: regen build release

regen:
	cd Sources && xcodegen generate

# `make build` does a Debug build via ./Scripts/build.sh.
# `make build release` switches to Release, which also packages a
# versioned DMG under Releases/ and tags git with the version when
# the working tree is clean.
build: regen
	./Scripts/build.sh $(if $(filter release,$(MAKECMDGOALS)),--release,)

# Marker target so `release` is valid after `build` on the command line.
# The build target reads MAKECMDGOALS to pick the configuration.
release:
	@:
