VERSION=1.0.0
DISTNAMEVER=calamari_$(VERSION)
PKGDIR=calamari-$(VERSION)
TARNAME = ../$(DISTNAMEVER).tar.gz
SRC := $(shell pwd)

INSTALL=/usr/bin/install

UI_BASEDIR = $(DESTDIR)/opt/calamari/webapp/content
UI_SUBDIRS = ui/admin ui/login clients/dashboard

CONFIG_JSON = clients/dashboard/dist/scripts/config.json

CONFFILES = \
	conf/diamond/CephCollector.conf \
	conf/diamond/NetworkCollector.conf \
	restapi/cephrestapi.conf \
	restapi/cephrestwsgi.py

# Strategy for building dist tarball: find what we know is source
# "grunt clean" doesn't take us back to a pristine source dir, so instead
# we filter out what we know is build product and tar up only what we
# want in sources.

# this is crazy convoluted to work around files with spaces in their names.
# also, debian is pruned because we want to add only specific parts of it
FINDCMD =find . \
        -name .git -prune \
        -o -name node_modules -prune \
        -o -name .tmp -prune \
        -o -name .sass-cache -prune \
        -o -name debian -prune \
        -o -print0

#DISTFILES=$(shell $(FINDCMD) | xargs -0 -n 1 | grep -v ' ')
#SPACEFILES=$(shell $(FINDCMD) | xargs -0 -n 1 -I % echo \"%\" | grep ' ')

# add in just the debian files we want
DEBFILES = \
	calamari-agent.install \
	calamari-agent.postinst \
	calamari-agent.prerm \
	calamari-webapp.init \
	calamari-webapp.docs \
	calamari-webapp.install \
	calamari-webapp.postinst \
	calamari-webapp.prerm \
	calamari-webapp.postrm \
	calamari-restapi.install \
	calamari-restapi.postinst \
	calamari-restapi.postrm \
	calamari-restapi.prerm \
	changelog \
	compat \
	control \
	copyright \
	rules \
	source/format

#DISTFILES += $(DEBFILES:%=debian/%)

build: build-ui $(CONFIG_JSON) $(CONFFILES)

build-ui:
	@echo "building ui subdirs"
	for d in $(UI_SUBDIRS); do \
		echo $$d; \
		(cd $$d; \
		npm install --silent; \
		bower --allow-root install; \
		grunt --no-color saveRevision; \
		grunt --no-color build; ) \
	done

# for right now, this contains two useful things that should be set
# when running against a live cluster.  We could preinstall it in the
# package or do it in a postinstall; it has more visibility here

$(CONFIG_JSON):
	echo '{ "offline": false, "graphite-host": "/graphite" }' \
		> $(CONFIG_JSON)


# this source is just not very amenable to building source packages.
# the Javascript directories don't really go back to "clean"; it might
# be possible to change that, but for now, just skip the source build
dpkg:
	dpkg-buildpackage -b -us -uc

install-common: build install-conf install-init install-ui install-graphite-venv install-calamari-venv
	@echo "install-common"

install-rpm: install-common install-rh-conf
	@echo "install-rpm"

# for deb
install: install-common install-deb-conf
	@echo "install"

install-conf: $(CONFFILES)
	@echo "install-conf"
	# Diamond conf files$
	@$(INSTALL) -D conf/diamond/CephCollector.conf \
		$(DESTDIR)/etc/diamond/collectors/CephCollector.conf
	@$(INSTALL) -D conf/diamond/NetworkCollector.conf \
		$(DESTDIR)/etc/diamond/collectors/NetworkCollector.conf
	# nginx/wsgi for ceph-rest-api
	@$(INSTALL) -D restapi/cephrestapi.conf \
		$(DESTDIR)/etc/nginx/conf.d/cephrestapi.conf
	@$(INSTALL) -D restapi/cephrestwsgi.py \
		$(DESTDIR)/etc/nginx/cephrestwsgi.py
	# wsgi conf for calamari
	@$(INSTALL) -D conf/calamari.wsgi \
		$(DESTDIR)/opt/calamari/conf/calamari.wsgi
	# wsgi conf for graphite constructed in postinst
	# log dirs for Django apps
	@$(INSTALL) -d $(DESTDIR)/var/log/graphite
	@$(INSTALL) -d $(DESTDIR)/var/log/calamari

install-deb-conf:
	# httpd conf for graphite and calamari vhosts, redhat
	@$(INSTALL) -D conf/httpd/debian/graphite.conf \
		$(DESTDIR)/etc/apache2/sites-available/graphite.conf
	@$(INSTALL) -D conf/httpd/debian/calamari.conf \
		$(DESTDIR)/etc/apache2/sites-available/calamari.conf
	# upstart job for cephrestapi
	@$(INSTALL) -D restapi/init/cephrestapi.conf \
		$(DESTDIR)/etc/init/cephrestapi.conf

install-rh-conf:
	# httpd conf for graphite and calamari vhosts, redhat
	@$(INSTALL) -D conf/httpd/rh/graphite.conf \
		$(DESTDIR)/etc/httpd/conf.d/graphite.conf
	@$(INSTALL) -D conf/httpd/rh/calamari.conf \
		$(DESTDIR)/etc/httpd/conf.d/calamari.conf
	# init job for cephrestapi
	@$(INSTALL) -D restapi/init.d/cephrestapi \
		$(DESTDIR)/etc/init.d/cephrestapi

install-init:
	@echo "install-init"
	@$(INSTALL) -D $(ROOTOG) conf/carbon/init.d/carbon-cache \
		$(DESTDIR)/etc/init.d/carbon-cache
	@$(INSTALL) -D $(ROOTOG) conf/upstart/kraken.conf \
		$(DESTDIR)/etc/init/kraken.conf

install-ui:
	@echo "install-ui"
	for d in $(UI_SUBDIRS); do \
		instdir=$$(basename $$d); \
		$(INSTALL) -d $(UI_BASEDIR)/$$instdir; \
		cp -rp $$d/dist/* $(UI_BASEDIR)/$$instdir; \
	done

# build venv for graphite

# graphite-web's requirements are obtained from a static copy of its
# requirements.txt from github, because obviously expressing those in setup.py
# or even including them in the stuff installed with setup.py would be just
# stupid.  Of course this depends on requirements.txt actually matching
# graphite-web's pip install. arrrrrrgh.
# XXX maybe at least add some kind of versioning check?...like what?...

# ugh, this just gets uglier.  virtualenv really really does not
# handle being installed in a different place than it will run.
# use the *install dirs* on the build machine (note: this means 
# running make will write to /opt/graphite and /opt/calamari.  Be 
# prepared for this!)  
# XXX consider an env var to set to protect against naive builders
# *EVEN BETTER*:
# carbon install, when it senses 'redhat' in platform.dist()[0], tries
# to install scripts to /etc/init.d.  THANKS.  Download, hack the setup.py,
# and install in three steps rather than one to accommodate this braindeath.

install-graphite-venv:
	@echo "install-graphite-venv"
	( cd /opt; \
	virtualenv graphite; \
	./graphite/bin/pip install whisper; \
	./graphite/bin/pip install --no-install carbon; \
	sed -i 's/== .redhat./== "DONTDOTHISredhat"/' \
		graphite/build/carbon/setup.py; \
	./graphite/bin/pip install --no-download carbon; \
	./graphite/bin/pip install graphite-web; \
	./graphite/bin/pip install -r $(SRC)/graphite-requirements.txt)
	# graphite local_settings.py
	@$(INSTALL) -D $(APACHEOG) -m 644 conf/graphite/local_settings.py \
		/opt/graphite/webapp/graphite/local_settings.py
	# copy it back from /opt/graphite to DESTDIR
	@$(INSTALL) -d -m 755 $(DESTDIR)/opt/graphite
	@cp -rp /opt/graphite $(DESTDIR)/opt

install-calamari-venv:
	@echo "install-calamari-venv"
	# copy calamari webapp files into place
	$(INSTALL) -d -m 755 /opt/calamari/webapp
	cp -rp webapp/* /opt/calamari/webapp
	# build venv for calamari
	$(INSTALL) -D $(ROOTOG) requirements.txt \
		$(DESTDIR)/opt/calamari/requirements.txt
	( cd /opt/calamari; \
	virtualenv venv; \
	./venv/bin/pip install -r $(SRC)/requirements.txt)
	# copy back to DESTDIR
	$(INSTALL) -d -m 755 $(DESTDIR)/opt/calamari/webapp
	@cp -rp /opt/calamari $(DESTDIR)/opt

clean:
	for d in $(UI_SUBDIRS); do \
		echo $$d; \
		(cd $$d; \
		npm install --silent; \
		bower install; \
		grunt --no-color clean) \
	done
	@rm -f $(CONFIG_JSON)


dist:
	@echo "making dist tarball in $(TARNAME)"
	for d in $(UI_SUBDIRS); do \
		echo $$d; \
		(cd $$d;  \
		npm install --silent; \
		grunt --no-color saveRevision) \
	done
	@rm -rf $(PKGDIR)
	@$(FINDCMD) | cpio --null -p -d $(PKGDIR)
	@tar -zcf $(TARNAME) $(PKGDIR)
	@rm -rf $(PKGDIR)
	@echo "tar file made in $(TARNAME)"

.PHONY: dist clean build build-venvs build-ui dpkg install install-conf 
.PHONY: install-init install-ui install-graphite-venv install-calamari-venv