# Instant Vultr OpenVPN Server

This script instantly creates an OpenVPN server on the Vultr cloud. This is useful as Vultr is billed hourly, and Vultr generously gives users 1TB of bandwidth on a newly created virtual server. By default, this script creates the 1GB server that is billed, at the time of writing, at $0.007/hr. 10 hours of usage is only 7 cents of Vultr credit, and the server can be considered disposable and destroyed when you are done with it from the Vultr admin console. Vultr also offers a $2.50/month server that is $.004/hour, but at the time of writing, it is almost always sold out, so it's hardly a real option. If you'd like to try it anyways, you can change `-p 201` to `-p 200` in the script. However, availability is very limited to the point where it's currently available only in Miami (region 39). 

## Usage

* Install the following packages on whatever distro you're using: `curl sshpass openvpn git`
* Export your Vultr API key and enable usage from your IP address in the Vultr console.
  * `export VULTR_API_KEY=[YOUR_API_KEY_HERE]`
* Checkout this repository and execute the `run.sh` script
  * `git clone https://github.com/dylanmtaylor/instant-vultr-vpn-server.git; cd instant-vultr-vpn-server; bash run.sh`
* Whenever you want your traffic to be routed through your VPN, run `sudo openvpn openvpn_cert.ovpn`

## Some technical details

* This repo contains a full copy of go that is compatible with the Vultr CLI written by James Clonk.
  * This CLI is utilized heavily in order to make API calls to the Vultr cloud
* The startup script is heavily based on Nyr's openvpn installations script. You can use this script to add additional users.
* The server name and name of the startup script is `openvpn_[the current Unix epoch time]`.
  * Once the server is up and running, the startup script is removed from your Vultr account for security reasons as it contains the root password
* A random root password is generated and set automatically. This is _different_ than the one Vultr assigns for security reasons.
* The entire startup script, including commands to install packages including OpenVPN and set the password is written to `temp_script`
* As a test, the script tries to write to `/root/success` on the server _immediately_, so even if nothing else works, you should see this file if the script ran
* When the script is done executing, the client certificate is stored to `/root/openvpn_cert.ovpn`
  * This script attempts to automatically copy openvpn_cert.ovpn to the working directory. This requires sshpass.
* For privacy reasons, this script defaults to configuring OpenVPN with the 1.1.1.1 DNS server from Cloudflare.

## Why not use Vultr's OpenVPN application template over this?

* This is not installed by Vultr. While they haven't given us any reason to not trust them, setting it up yourself puts you in control, and they do not have access to any of the passwords.
* This is significantly faster. The Vultr image provides you with an admin panel for OpenVPN and you get to spend time setting up users through it and clicking through pages on a web interface. This is a single command.
 * Having nothing to configure makes the server more disposable, as less time is invested in setting it up.
* In theory, this is harder for the provider to know that OpenVPN is running on the server at all, as it's not installed through their template.
* This downloads the latest OpenVPN version available and the latest CentOS operating system packages. The template may not necessarily be up to date. By the time the script is done running, you have a fully patched system.
