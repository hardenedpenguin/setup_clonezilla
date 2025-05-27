# setup_clonezilla

This is a simple script to download and setup a usb drive with clonezilla. You also have the option while script is running to add 
a backup to the device for use from the internet. Any modifications please feel free to send them my way.

For The Dell 3040 to be used with asl3 please provide the url when asked, this backup file is a generic install of debian 12,
I simply added asl and asl3-pi-appliance to help users along. We also have updated NetworkManager to manage all net devices, along
with blacklisting the dw_dmac_core module so your node will reboot and shutdown if you so wish.
```
http://w5gle.us/~anarchy/Dell-3040-2025-01-30-img.zip
```
The default username/password is hamradio, you can use passwd after login to change it, you might also need to reconfigure your
timezone. This can be accomplished with the following command
```
sudo dpkg-reconfigure tzdata
```
To create your own user run the following command and follow the prompts
```
sudo adduser username
sudo adduser username sudo
```
Once you have added your own personal user, logout of hamradio and into your new account. We can remove the old account with a simple
command that will remove all the hamradio user files
```
sudo deluser --remove-all-files hamradio
```
You are ready to configure your asl3 node as normal.
