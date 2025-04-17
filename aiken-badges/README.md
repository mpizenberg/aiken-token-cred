# Badges

This folder provides the main `check_badges` validator, with the badge validation logic.

For convenience, it also provides a `mint_badge` validator, to help minting badges, which are tokens with unique policy IDs.
But any token with a unique policy ID can be used as a badge, there is no explicit need for the `mint_badge` validator.
Beware to not use fungible tokens, or NFTs collections since these do not have unique policy IDs.
