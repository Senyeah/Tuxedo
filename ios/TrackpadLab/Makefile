# Trackpad Lab's pure Swift tests, apart from the root Makefile so that no file Henge builds
# changes before the approval (docs/external-trackpad-plan.md). From the repository root:
#   make -C ios/TrackpadLab test
ROOT := $(abspath ../..)
B := $(ROOT)/build/trackpad-lab-tests
PAD := $(ROOT)/ios/Pad
SWIFTC := xcrun --sdk macosx swiftc -O -parse-as-library

test: test-pad-field test-pad-layout test-pointer-buttons test-pad-motion
.PHONY: test test-pad-field test-pad-layout test-pointer-buttons test-pad-motion

$(B):
	mkdir -p $@

$(B)/test_pad_field: $(PAD)/PadTuning.swift $(PAD)/PadField.swift $(ROOT)/tests/test_pad_field.swift | $(B)
	$(SWIFTC) $^ -o $@

$(B)/test_pad_layout: $(PAD)/PadTuning.swift $(PAD)/PadLayout.swift $(ROOT)/tests/test_pad_layout.swift | $(B)
	$(SWIFTC) $^ -o $@

$(B)/test_pointer_buttons: $(PAD)/PointerButtons.swift $(ROOT)/tests/test_pointer_buttons.swift | $(B)
	$(SWIFTC) $^ -o $@

$(B)/test_pad_motion: $(PAD)/PadTuning.swift $(PAD)/PadMotionFeel.swift $(ROOT)/tests/test_pad_motion.swift | $(B)
	$(SWIFTC) $^ -o $@

test-pad-motion: $(B)/test_pad_motion
	$<

test-pad-field: $(B)/test_pad_field
	$<

test-pad-layout: $(B)/test_pad_layout
	$<

test-pointer-buttons: $(B)/test_pointer_buttons
	$<
