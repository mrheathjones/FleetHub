# Delivering Secrets by Jamf Policy

FleetHub keeps the Platform integration secret and, only when automatic API client creation is turned on, the provisioning (master) client secret in each user's Keychain. They get there by being typed into the app, or by a Jamf policy running [`Deployment/Import-FleetHub-Credentials.sh`](../Deployment/Import-FleetHub-Credentials.sh) (also downloadable and uploadable from Setup's Credential Delivery tab) after the package installs:

| Parameter | Value |
|---|---|
| 4 | Jamf Pro provisioning client ID |
| 5 | Jamf Pro provisioning client secret |
| 6 | Jamf Platform API client ID |
| 7 | Jamf Platform API client secret |
| 8 | Apple Business Manager key ID |
| 9 | Apple Business Manager private key (.pem), base64-encoded on one line |
| 10 | Entra device cleanup app (client) ID |
| 11 | Entra device cleanup client secret |

The script runs FleetHub's import command as the logged-in user (`FleetHub --import-credential jamfPro|platform|abm|entra --client-id <id> [--base64]`, secret on standard input; for `abm` the identifier is the ABM key ID and the key arrives base64-encoded). FleetHub stores the secret for that client ID and uses it only while the Core profile names the same client ID. Set the policy to Ongoing with the Recurring Check-in and Login triggers; re-running with unchanged values does nothing.

To rotate: create a new client, put its ID and secret in the policy, then change the client ID in the Core profile, then delete the old client. The secrets are stored in Jamf Pro on the policy, so limit who can view it.

The script runs **after** the package installs (script priority After), so the app is present when it runs. See [`Deployment/README.md`](../Deployment/README.md) for the policy itself.
