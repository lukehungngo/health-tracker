# ADR 0012: Rolling net calories on Today

Status: accepted, 2026-10-02.

Today shows rolling 7- and 30-calendar-day net calories, including the current
day only up to now. Net is logged meal kcal minus recorded or explicitly
estimated burned kcal, matching Calendar's deficit/surplus sign and colors.

Only meals already eaten as of now are considered. Only days with at least one
logged meal, kcal estimates for every counted meal,
and a non-partial burned-energy result contribute to the total. An unlogged
day is unknown, not zero intake; a day without enough body/energy data is
also unknown. The card shows how many days contributed, and displays `—` if
none did. This subtotal is not a claim that all food eaten was logged.

The 30-day view loads each calendar month touched by the window, rather than
just the current month. New meal estimates or synced energy refresh the
display without rewriting historical daily records.
