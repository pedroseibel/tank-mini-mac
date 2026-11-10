import Foundation
import TankMiniCore

// Localisation: the interface is written in English and translated through the app
// bundle's Localizable.strings (Resources/pt-BR.lproj). SwiftUI looks up literal strings
// by itself; `L` does the same for strings built in code.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

extension Module {
    var localizedTitle: String { L(title) }
}

/// What each model on the pedal is, in plain words.
///
/// M-VAVE does not publish which real gear its amp and cabinet models are captured
/// from. The "based on" names below are read from the pedal's own abbreviated model
/// names, so each one is marked as likely or only possible. Product names belong to
/// their owners and are used only to describe the sound.
struct ModelNote {
    /// Real-world gear the model appears to be based on; nil when the name gives no clue.
    var gear: String?
    /// False when the name only hints at the gear.
    var confident = true
    /// One sentence on how it sounds.
    var sound: String
}

enum ModelGuide {
    static let amps: [String: ModelNote] = [
        "UWE-Twins": ModelNote(gear: "Fender Twin Reverb", sound: "Loud, glassy American clean with lots of headroom. A good base for effects."),
        "UK-C30Normal": ModelNote(gear: "Vox AC30, Normal channel", sound: "Chiming British clean that turns into a jangly crunch as Gain rises."),
        "MarsVM410": ModelNote(gear: "Marshall JVM410", sound: "Modern Marshall, from tight crunch to saturated lead."),
        "Victor_Mars": ModelNote(gear: "a Victory or Marshall-style British head", confident: false, sound: "British crunch with a strong midrange."),
        "BritPLEX_100": ModelNote(gear: "Marshall Super Lead 100 “Plexi”", sound: "Classic rock crunch: open, dynamic, and it cleans up when you pick softly."),
        "MarsFD100": ModelNote(gear: "Friedman BE-100, a hot-rodded Marshall design", confident: false, sound: "Thick, hot-rodded British high gain."),
        "Eagle_SAVAGE": ModelNote(gear: "ENGL Savage 120", sound: "Aggressive, tight German high gain for metal rhythm."),
        "TH_DieselHgn": ModelNote(gear: "Diezel Hagen", sound: "Dense modern high gain with a firm low end."),
        "PvEV5150": ModelNote(gear: "Peavey / EVH 5150", sound: "Saturated American high gain, the standard hard rock and metal rhythm sound."),
        "FORTIN_CALI": ModelNote(gear: "Fortin Cali", sound: "Very tight, percussive modern metal gain."),
        "MESS_MktCln2": ModelNote(gear: "Mesa/Boogie Mark series, clean channel", sound: "Warm, full clean with a firm bottom."),
        "CA-tweed": ModelNote(gear: "a 1950s Fender tweed amp", sound: "Warm, raw vintage sound that breaks up early."),
        "BogSV20": ModelNote(gear: "Bogner Shiva 20th Anniversary", confident: false, sound: "Smooth, rich overdrive with a bold midrange."),
        "JUICE_JIM": ModelNote(gear: "Orange #4 Jim Root Terror", sound: "Thick British high gain with a fuzzy edge."),
        "Sur_SL68": ModelNote(gear: "Suhr SL68, a Plexi-style head", sound: "Refined Plexi crunch, clear and punchy."),
        "BassADAtube": ModelNote(gear: "ADA tube bass preamp", confident: false, sound: "Tube-warm bass tone with smooth drive."),
        "BassAlmbic": ModelNote(gear: "Alembic F-2B preamp", sound: "Clean, hi-fi bass tone with deep lows and clear highs."),
        "BassG800K_7": ModelNote(gear: "Gallien-Krueger 800RB", sound: "Punchy, growling solid-state bass tone."),
        "BassTR-Trad": ModelNote(gear: "a Trace Elliot bass head", confident: false, sound: "Traditional, rounded bass tone."),
        "BassMarkT501": ModelNote(gear: "Markbass TTE 501 tube head", sound: "Warm, clear modern bass tone."),
    ]

    static let cabs: [String: ModelNote] = [
        "EAGLProV30s": ModelNote(gear: "ENGL Pro 4x12 with Celestion Vintage 30s", sound: "Tight and focused, with the Vintage 30’s upper-mid bite."),
        "Sperimental": ModelNote(gear: nil, sound: "The name gives no clear real-world match. Try it by ear."),
        "JUICE4x12V30": ModelNote(gear: "Orange PPC412 with Vintage 30s", sound: "Big and thick in the low mids."),
        "Mess Bog": ModelNote(gear: "a Mesa/Boogie and Bogner 4x12 blend", confident: false, sound: "Full, balanced modern rock cabinet."),
        "FdChamp": ModelNote(gear: "Fender Champ, 1x8", sound: "Small, boxy and midrange-forward."),
        "FdPrJunir": ModelNote(gear: "Fender Pro Junior, 1x10", sound: "Bright, lively small-combo sound."),
        "Mar960BV30": ModelNote(gear: "Marshall 1960B 4x12 with Vintage 30s", sound: "Classic rock stack sound with extra mid bite."),
        "DizzlV30": ModelNote(gear: "Diezel 4x12 with Vintage 30s", sound: "Deep low end that stays tight under high gain."),
        "Electrovoice": ModelNote(gear: "an Electro-Voice EVM12L speaker", sound: "Clean, full-range and punchy. Stays clear at high gain."),
        "MessDRectV30": ModelNote(gear: "Mesa/Boogie Rectifier 4x12 with Vintage 30s", sound: "Big lows and aggressive mids, the modern metal cabinet."),
        "TwinJensenC": ModelNote(gear: "Fender Twin 2x12 with Jensen C12 speakers", sound: "Bright, sparkling American clean."),
        "TwedDlx1X12": ModelNote(gear: "Fender Tweed Deluxe, 1x12", sound: "Warm, loose and rich in midrange."),
        "FendShowman": ModelNote(gear: "Fender Showman cabinet", sound: "Big, clear surf-style clean."),
        "J120Rolnd": ModelNote(gear: "Roland JC-120 Jazz Chorus, 2x12", sound: "Very clean and even. The classic match for chorus."),
        "UK-C30Silvers": ModelNote(gear: "Vox AC30 2x12 with Celestion Silver alnico speakers", sound: "Chiming top end with a soft, sweet breakup."),
        "BassAgula25": ModelNote(gear: "an Aguilar bass cabinet", confident: false, sound: "Warm, punchy modern bass cabinet."),
        "BassJensen10": ModelNote(gear: "a bass cabinet with Jensen 10-inch speakers", sound: "Tight vintage low end."),
        "BassFdBassman": ModelNote(gear: "Fender Bassman cabinet", sound: "Round vintage bass tone."),
        "BassAmpg410": ModelNote(gear: "Ampeg SVT 4x10", sound: "Punchy, defined bass with a quick attack."),
        "BassEDN300": ModelNote(gear: "an Eden bass cabinet", confident: false, sound: "Clear, hi-fi bass with extended highs."),
    ]

    /// Effect types, keyed by the model name shown in the picker.
    static let effects: [Module: [String: String]] = [
        .fx: [
            "Noise Gate": "Mutes hiss and hum while you are not playing.",
            "Boost": "Pushes the signal harder into the amp for more drive.",
            "Compressor": "Evens out loud and soft notes and adds sustain.",
        ],
        .mod: [
            "Chorus": "Layers a slightly detuned copy for a wider, shimmering sound.",
            "Phaser": "Sweeps notches through the tone for a swirling movement.",
            "Tremolo": "Pulses the volume up and down.",
            "Flanger": "A short sweeping delay that gives a jet-like whoosh.",
            "Vibrato": "Wobbles the pitch itself.",
            "Univibe": "The thick, throbbing swirl of a 1960s Uni-Vibe.",
            "Autofilter": "A filter that sweeps on its own, like an automatic wah.",
        ],
        .delay: [
            "Analog": "Warm, dark repeats that fade naturally, like a bucket-brigade delay.",
            "Duck": "Repeats stay quiet while you play and rise when you stop.",
            "Tape": "Tape-echo repeats with wobble and grit.",
            "Dual": "Two delay lines at once, for rhythmic patterns.",
            "Lo-fi": "Degraded, gritty repeats.",
        ],
        .reverb: [
            "Room": "A small room: short and natural.",
            "Hall": "A large hall: long and spacious.",
            "Swell": "Reverb that fades in behind each note.",
            "Spring": "The bright, splashy spring tank of a vintage amp.",
            "Shimmer": "Adds an octave-up halo above the reverb tail.",
            "Cloud": "A long, diffuse wash for ambient sounds.",
        ],
    ]

    /// Headline ("Likely based on ...") and one-sentence description for a model, localised.
    static func note(module: Module, modelName: String) -> (headline: String?, detail: String) {
        func localized(_ prefix: String, _ english: String) -> String {
            Bundle.main.localizedString(forKey: "\(prefix).\(modelName)", value: english, table: nil)
        }
        switch module {
        case .amp, .cab:
            guard let note = (module == .amp ? amps : cabs)[modelName] else {
                return (nil, L("No notes for this model. It may be one you loaded yourself."))
            }
            let headline: String
            if let gear = note.gear {
                let format = note.confident ? L("Likely based on %@") : L("Possibly based on %@")
                headline = String(format: format, localized("gear", gear))
            } else {
                headline = L("Not identified")
            }
            return (headline, localized("guide", note.sound))
        default:
            guard let text = effects[module]?[modelName] else { return (nil, "") }
            return (nil, Bundle.main.localizedString(forKey: "guide.\(module.code).\(modelName)", value: text, table: nil))
        }
    }
}
