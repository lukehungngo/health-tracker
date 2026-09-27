# Personal Health Tracker

Terms used for personal body values and calorie estimates in the app.

## Language

**Fat-free mass**:
Body mass excluding fat, including muscle, bone, organs, and water. It is not skeletal muscle mass.
_Avoid_: Muscle mass

**Gender for formula**:
The male or female coefficient selected for the resting-energy formula, from Apple Health or a manual override. It is not a statement about gender identity.
_Avoid_: Sex in user-facing labels

**Maintenance intake**:
Estimated daily energy intake to maintain body weight, not a measured burn or a weight-loss target. An AI/manual entry becomes effective on its recorded local date and carries forward until the next entry; later entries do not rewrite earlier dates.
_Avoid_: Recommended calories

**Recorded energy**:
HealthKit basal plus active energy for hours with synced energy samples. Workout energy is not added again.

**Estimated gap energy**:
An app-derived total for an hour without any synced basal or active energy samples. It uses an app-entered weight and a labeled sleep or seated-work assumption; it is not a HealthKit sample.

**Daily burned**:
Recorded energy plus estimated gap energy, through the current time for today. Logged intake is the sum of available meal estimates and may be partial; it is not the maintenance intake target.

**Protein target**:
An editable daily protein range in grams, entered in the app or supplied by AI. The previous body-composition formula remains a fallback only. It is distinct from estimated protein eaten in meals.
