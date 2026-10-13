#!/usr/bin/env python3
"""Keep the dominant hand a game sets, and tell the host.

Half-Life: Alyx ships binding files for a right-handed player only (Fire on
the right trigger in every one). With its "Weapon Hand" option set to left it
calls IVRInput::SetDominantHand(LeftHand) and expects the runtime to drive the
bindings written for one hand's controls from the other controller, as SteamVR
does (Glovebox's finding, github.com/glovebox-vr/glovebox, klvr_input.cpp).
Upstream xrizer logs the call as unimplemented and drops it, so the gun moves
to the left hand and the trigger that fires it stays on the right.

OpenXR has no way to rebind after the action sets are attached, so the swap is
the host's: here the hand is remembered (GetDominantHand answers with it) and
written, one byte "L" or "R", to /dev/klepton-dominant-hand — a path Klepton's
Linux runtime answers (runtime/linux/kl_lx_interstitial.c) and nothing else
has, so on any other system the open fails and nothing changes.

Run from the xrizer checkout; fails loudly if upstream moved.
"""
import pathlib
import sys

p = pathlib.Path("src/input.rs")
s = p.read_text()
old = """    fn SetDominantHand(&self, _: vr::ETrackedControllerRole) -> vr::EVRInputError {
        crate::warn_unimplemented!("SetDominantHand");
        vr::EVRInputError::None
    }
    fn GetDominantHand(&self, _: *mut vr::ETrackedControllerRole) -> vr::EVRInputError {
        crate::warn_unimplemented!("GetDominantHand");
        vr::EVRInputError::None
    }
"""
new = """    fn SetDominantHand(&self, role: vr::ETrackedControllerRole) -> vr::EVRInputError {
        use std::io::Write;
        static SINK: Mutex<Option<std::fs::File>> = Mutex::new(None);
        let left = matches!(Hand::try_from(role), Ok(Hand::Left));
        KL_DOMINANT_LEFT.store(left, Ordering::Relaxed);
        let mut sink = SINK.lock().unwrap();
        if sink.is_none() {
            *sink = std::fs::OpenOptions::new()
                .write(true)
                .open("/dev/klepton-dominant-hand")
                .ok();
        }
        if let Some(f) = sink.as_mut() {
            let _ = f.write_all(if left { b"L" } else { b"R" });
        }
        vr::EVRInputError::None
    }
    fn GetDominantHand(&self, role: *mut vr::ETrackedControllerRole) -> vr::EVRInputError {
        if role.is_null() {
            return vr::EVRInputError::InvalidParam;
        }
        let hand = if KL_DOMINANT_LEFT.load(Ordering::Relaxed) {
            Hand::Left
        } else {
            Hand::Right
        };
        unsafe { role.write(hand.into()) };
        vr::EVRInputError::None
    }
"""
anchor = "macro_rules! get_subaction_path {"
if old not in s or s.count(anchor) != 1:
    sys.exit("xrizer-dominant-hand: this is not the source it was written for")
s = s.replace(old, new, 1)
s = s.replace(
    anchor,
    "/// The hand a game named with SetDominantHand; right until it says otherwise.\n"
    "static KL_DOMINANT_LEFT: AtomicBool = AtomicBool::new(false);\n\n" + anchor,
    1,
)
p.write_text(s)
