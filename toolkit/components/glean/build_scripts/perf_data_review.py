# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Produce skeleton Performance Data Review Requests.

This was mostly copies from glean_parser, and should be kept in sync.
"""

import re
from collections.abc import Sequence
from pathlib import Path

from glean_parser import parser, util


def generate(
    bug: str,
    metrics_files: Sequence[Path],
) -> int:
    """
    Commandline helper for Data Review Request template generation.

    :param bug: pattern to match in metrics' bug_numbers lists.
    :param metrics_files: List of Path objects to load metrics from.
    :return: Non-zero if there were any errors.
    """

    metrics_files = util.ensure_list(metrics_files)

    # Accept any value of expires.
    parser_options = {
        "allow_reserved": True,
        "custom_is_expired": lambda expires: False,
        "custom_validate_expires": lambda expires: True,
    }
    all_objects = parser.parse_objects(metrics_files, parser_options)

    if util.report_validation_errors(all_objects):
        return 1

    # I tried [\W\Z] but it complained. So `|` it is.
    reobj = re.compile(f"\\W{bug}\\W|\\W{bug}$")
    durations = set()
    responsible_emails = set()
    metrics_table = ""
    for category_name, metrics in all_objects.value.items():
        for metric in metrics.values():
            if not any([len(reobj.findall(bug)) == 1 for bug in metric.bugs]):
                continue

            metric_name = util.snake_case(metric.name)
            category_name = util.snake_case(category_name)
            one_line_desc = metric.description.replace("\n", " ")
            sensitivity = ", ".join([s.name for s in metric.data_sensitivity])
            last_bug = metric.bugs[-1]
            metrics_table += f"`{category_name}.{metric_name}` | "
            metrics_table += f"{one_line_desc} | {sensitivity} | {last_bug}\n"
            if metric.type == "event" and len(metric.allowed_extra_keys):
                for extra_name, extra_detail in metric.extra_keys.items():
                    extra_one_line_desc = extra_detail["description"].replace("\n", " ")
                    metrics_table += f"`{category_name}.{metric_name}#{extra_name}` | "
                    metrics_table += (
                        f"{extra_one_line_desc} | {sensitivity} | {last_bug}\n"
                    )

            durations.add(metric.expires)

            if metric.expires == "never":
                responsible_emails.update(metric.notification_emails)

    if len(durations) == 1:
        duration = next(iter(durations))
        if duration == "never":
            collection_duration = "This collection will be collected permanently."
        else:
            collection_duration = f"This collection has expiry '{duration}'"
    else:
        collection_duration = "Parts of this collection expire at different times: "
        collection_duration += f"{durations}"

    if "never" in durations:
        collection_duration += "\n" + ", ".join(responsible_emails) + " "
        collection_duration += "will be responsible for the permanent collections."

    if len(durations) == 0:
        print(f"I'm sorry, I couldn't find metrics matching the bug number {bug}.")
        return 1

    # This template is pulled from
    # https://github.com/mozilla/data-review/blob/main/request.md
    print(
        """
!! Reminder: it is your responsibility to complete and check the correctness of
!! this automatically-generated request skeleton before requesting Data
!! Collection Review. See https://wiki.mozilla.org/Data_Collection for details.

DATA REVIEW REQUEST
1. What questions will you answer with this data?

TODO: Fill this in.

2. Why does Mozilla need to answer these questions? Are there benefits for users?
   Do we need this information to address product or business requirements?

In order to guarantee the performance of our products, it is vital to monitor
real-world installs used by real-world users.

3. What alternative methods did you consider to answer these questions?
   Why were they not sufficient?

Our ability to measure the practical performance impact of changes through CI
and manual testing is limited. Monitoring the performance of our products in
the wild among real users is the only way to be sure we have an accurate
picture.

4. Can current instrumentation answer these questions?

No.

5. List all proposed measurements and indicate the category of data collection for each
   measurement, using the Firefox data collection categories found on the Mozilla wiki.

Measurement Name | Measurement Description | Data Collection Category | Tracking Bug
---------------- | ----------------------- | ------------------------ | ------------"""
    )
    print(metrics_table)
    print(
        """
6. Please provide a link to the documentation for this data collection which
   describes the ultimate data set in a public, complete, and accurate way.

This collection is Glean so is documented
[in the Glean Dictionary](https://dictionary.telemetry.mozilla.org).

7. How long will this data be collected?
"""
    )
    print(collection_duration)
    print(
        """
8. What populations will you measure?

All channels, countries, and locales. No filters.

9. If this data collection is default on, what is the opt-out mechanism for users?

These collections are Glean. The opt-out can be found in the product's preferences.

10. Please provide a general description of how you will analyze this data.

This will be continuously monitored for regression and improvement detection.

11. Where do you intend to share the results of your analysis?

Internal monitoring (GLAM, Redash, Looker, etc.).

12. Is there a third-party tool (i.e. not Telemetry) that you
    are proposing to use for this data collection?

No.
"""
    )

    return 0
