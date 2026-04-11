PACKAGE = jt-pve-storage-netapp
VERSION = 0.2.7
RELEASE = 1

DESTDIR =
PERL5DIR = $(DESTDIR)/usr/share/perl5

.PHONY: all install clean deb

all:
	@echo "Nothing to build. Run 'make install' or 'make deb'"

install:
	install -d $(PERL5DIR)/PVE/Storage/Custom
	install -d $(PERL5DIR)/PVE/Storage/Custom/NetAppONTAP
	install -m 0644 lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm $(PERL5DIR)/PVE/Storage/Custom/
	install -m 0644 lib/PVE/Storage/Custom/NetAppONTAP/*.pm $(PERL5DIR)/PVE/Storage/Custom/NetAppONTAP/

uninstall:
	rm -f $(PERL5DIR)/PVE/Storage/Custom/NetAppONTAPPlugin.pm
	rm -rf $(PERL5DIR)/PVE/Storage/Custom/NetAppONTAP

deb:
	dpkg-buildpackage -b -us -uc

clean:
	rm -rf debian/.debhelper
	rm -rf debian/jt-pve-storage-netapp
	rm -f debian/files
	rm -f debian/debhelper-build-stamp
	rm -f debian/*.debhelper
	rm -f debian/*.substvars
	rm -f ../$(PACKAGE)_*.deb
	rm -f ../$(PACKAGE)_*.buildinfo
	rm -f ../$(PACKAGE)_*.changes

test:
	perl -Ilib -c lib/PVE/Storage/Custom/NetAppONTAP/Naming.pm
	perl -Ilib -c lib/PVE/Storage/Custom/NetAppONTAP/API.pm
	perl -Ilib -c lib/PVE/Storage/Custom/NetAppONTAP/ISCSI.pm
	perl -Ilib -c lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm
	perl -Ilib -c lib/PVE/Storage/Custom/NetAppONTAP/FC.pm
	perl -Ilib -c lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  install   - Install plugin to system (requires root)"
	@echo "  uninstall - Remove plugin from system (requires root)"
	@echo "  deb       - Build Debian package"
	@echo "  clean     - Clean build artifacts"
	@echo "  test      - Syntax check all Perl modules"
