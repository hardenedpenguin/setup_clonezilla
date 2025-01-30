# setup_clonezilla

This is a simple script to download and setup a usb drive with clonezilla. You also have the option while script is running to add 
a backup to the device for use from the internet. Any modifications please feel free to send them my way.

For The Dell 3040 to be used with asl3 please provide the url when asked
```
https://dev.gentoo.org/~anarchy/Dell-3040-2025-01-30-img.zip
```
The default username/password is hamradio, you can use passwd after login to change it, you might also need to reconfigure your
timezone. This can be accomplished with the following command
```
sudo dpkg-reconfigure tzdata
```
