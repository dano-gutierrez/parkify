# Parkify

Parkify is a native San Francisco parking assistant for iPhone, built with SwiftUI, MapKit, Core Location, Core Motion, AlarmKit and WidgetKit. It downloads public city data and evaluates curb rules on the phone. Parking coordinates, motion events, residential permits and payments stay on the device. When you request directions or walking distances, MapKit uses Apple Maps.

## Run on iPhone

Open `Parkify.xcodeproj` in Xcode 26 or newer. Select the Parkify scheme, your iPhone and a signing team with the app group enabled on both targets. The deployment target is iOS 26. The first launch downloads and verifies the city database. Settings shows download status and supports a retry. Manual parking and entered signs work before the download completes.

Tap a colored curb to see its current parking rules. Tap **Park here**, drag the pin onto the correct side of the street, then save. The card shows when to move. Expand it to edit the sign or arrival time, adjust the pin, or end parking. **Find another curb** marks nearby options on the map. Tap a number to see the move deadline and open driving directions in Apple Maps. Select the alarm button to approve a system alarm. Add **Parkify → Parking countdown** when customizing your Lock Screen. Enable automatic detection in Parkify Settings, then allow precise background location and Motion & Fitness. Background delivery depends on iOS and real-world location accuracy.

## Data releases

The daily GitHub Actions importer reads [SFMTA Digital Curb](https://data.sf.gov/d/wntw-x37e), [Public Works sweeping schedules](https://data.sf.gov/d/yhqp-riqs), [temporary tow postings](https://data.sf.gov/d/6r5h-j298), [meter inventory](https://data.sf.gov/d/8vzz-qzz9), [meter policies](https://data.sf.gov/d/qq7v-hds4), and [SFMTA holiday enforcement guidance](https://www.sfmta.com/getting-around/drive-park/holiday-enforcement-schedule). It deduplicates policies, builds a spatial SQLite index, checks integrity and coverage, and publishes compressed, checksum-verified parts. Each release becomes current after all parts are uploaded. [Current city release](https://github.com/dano-gutierrez/parkify/releases/latest)

The app checks for updates on launch and when iOS grants background time. Posted signs take precedence. The city’s temporary tow inventory may lack current permits and exact frontage. Unknown conditions appear as **Check signs**. Nearby suggestions describe mapped restrictions and require checking the actual curb.

City downloads are served by the public `parkify-curbs` bucket in the existing Bucketlist Supabase project, with GitHub Releases as a fallback. The `parkify-publish` Edge Function validates the GitHub Actions identity, repository ID, main branch and publication workflow. It grants short-lived upload URLs for individual Parkify objects. The workflow publishes the manifest last and retains three snapshots in the dedicated bucket. No Bucketlist service credential is stored in GitHub or the iPhone app. [Live Supabase manifest](https://bqmjackxfpwxptkqjseg.supabase.co/storage/v1/object/public/parkify-curbs/manifest.json)

## Verification

Run `swift test` for the focused rule and curb-matching tests. The **Verify iPhone build** action compiles both targets and launches the app on a simulator. Physical acceptance includes a drive-to-walk transition, a manual curb correction, a locked-screen alarm, and an offline countdown.
