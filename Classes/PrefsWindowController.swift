//
//  PrefsWindowController.swift
//  Subler
//
//  Created by Damiano Galassi on 20/08/2017.
//

import Cocoa

class PrefsWindowController: NSWindowController {

    public class func registerUserDefaults() {
        let defaults = UserDefaults.standard
        let movieDefaultMap = NSKeyedArchiver.archivedData(withRootObject: MetadataResultMap.movieDefaultMap)
        let tvShowDefaultMap = NSKeyedArchiver.archivedData(withRootObject: MetadataResultMap.tvShowDefaultMap)

        let encoder = JSONEncoder()

        let movieFormat = try? encoder.encode([Token(text: "{Name}")])
        let tvShowFormat = try? encoder.encode([Token(text: "{TV Show}"), Token(text: " s", isPlaceholder: false), Token(text: "{TV Season}"), Token(text: "e", isPlaceholder: false), Token(text: "{TV Episode #}")])

        if defaults.integer(forKey: "SBUpgradeCheck") < 1 {
            // Migrate 1.2.9 DTS setting
            if defaults.object(forKey: "SBAudioKeepDts") != nil {
                if defaults.bool(forKey: "SBAudioKeepDts") {
                    defaults.set(2, forKey: "SBAudioDtsOptions")
                }
                defaults.removeObject(forKey: "SBAudioKeepDts")
            }

            // Migrate 1.4.8 filename format settings
            let oldMovieFormat = defaults.tokenArrayFromOldStylePrefs(forKey: "SBMovieFormat")
            if oldMovieFormat.isEmpty == false {
                defaults.set(oldMovieFormat, forKey: "SBMovieFormatTokens")
            }
            let oldTvShowFormat = defaults.tokenArrayFromOldStylePrefs(forKey: "SBTVShowFormat")
            if oldTvShowFormat.isEmpty == false {
                defaults.set(oldTvShowFormat, forKey: "SBTVShowFormatTokens")
            }

            defaults.set(1, forKey: "SBUpgradeCheck")
        }

        let settings: [String: Any] = ["SBSaveFormat":                  "m4v",
                                       "defaultSaveFormat":             "0",
                                       "SBOrganizeAlternateGroups":     true,
                                       "SBInferMediaCharacteristics":   false,
                                       "SBAudioMixdown":                "1",
                                       "SBAudioBitrate":                "96",
                                       "SBAudioConvertAC3":             true,
                                       "SBAudioKeepAC3":                true,
                                       "SBAudioConvertDts":             true,
                                       "SBAudioDtsOptions":             0,
                                       "SBSubtitleConvertBitmap":       true,
                                       "SBRatingsCountry":              "All countries",
                                       "mp464bitOffset":                false,
                                       "chaptersPreviewTrack":          true,
                                       "SBChaptersPreviewPosition":     0.5,

                                       "SBMovieFormatTokens":           movieFormat ?? "",
                                       "SBTVShowFormatTokens":          tvShowFormat ?? "",
                                       "SBSetMovieFormat":              false,
                                       "SBSetTVShowFormat":             false,

                                       "SBMetadataPreference|Movie":                       "TheMovieDB",
                                       "SBMetadataPreference|Movie|iTunes Store|Language": "USA (English)",
                                       "SBMetadataPreference|Movie|TheMovieDB|Language":   "en",

                                       "SBMetadataPreference|TV":                       "TheTVDB",
                                       "SBMetadataPreference|TV|iTunes Store|Language": "USA (English)",
                                       "SBMetadataPreference|TV|TheTVDB|Language":      "en",
                                       "SBMetadataPreference|TV|TheMovieDB|Language":   "en",

                                       "SBMetadataMovieResultMap":       movieDefaultMap,
                                       "SBMetadataTvShowResultMap":      tvShowDefaultMap,
                                       "SBMetadataKeepEmptyAnnotations": false,

                                       "SBFileImporterImportMetadata": true,
                                       
                                       "SBForceHvc1": true]

        defaults.register(defaults: settings)
    }

    override var windowNibName: NSNib.Name? {
        return NSNib.Name(rawValue: "PrefsWindowController")
    }

    lazy var tabsViewController: NSTabViewController = {
        let controller = PrefsTabViewController()

        controller.tabStyle = NSTabViewController.TabStyle.toolbar
        controller.transitionOptions = [NSViewController.TransitionOptions.allowUserInteraction]
        controller.canPropagateSelectedChildViewControllerTitle = true

        let general = NSTabViewItem(viewController: GeneralPrefsViewController())
        general.image = NSImage.init(imageLiteralResourceName: "NSPreferencesGeneral")
        controller.addTabViewItem(general)

        let metadata = NSTabViewItem(viewController: MetadataPrefsViewController())
        metadata.image = NSImage.init(imageLiteralResourceName: "NSUserAccounts")
        controller.addTabViewItem(metadata)

        let presets = NSTabViewItem(viewController: PresetPrefsViewController())
        presets.image = NSImage.init(imageLiteralResourceName: "NSFolderSmart")
        controller.addTabViewItem(presets)

        let output = NSTabViewItem(viewController: OutputPrefsViewController())
        output.image = NSImage.init(imageLiteralResourceName: "mp4-file")
        controller.addTabViewItem(output)

        let advanced = NSTabViewItem(viewController: AdvancedPrefsViewController())
        advanced.image = NSImage.init(imageLiteralResourceName: "NSAdvanced")
        controller.addTabViewItem(advanced)

        return controller
    }()

    override func windowDidLoad() {
        super.windowDidLoad()
        contentViewController = tabsViewController
        window?.title = tabsViewController.tabView.selectedTabViewItem?.label ?? ""
    }

}
