# Credits to https://github.com/danielkrupinski/OneByteWallhack

from pyMeow import *

pm = open_process(processName="csgo.exe")
address = aob_scan_module(pm, "client.dll", "33 C0 83 FA ?? B9 20")[0]
w_byte(pm, address + 4, 2 if r_byte(pm, address) == 1 else 1)