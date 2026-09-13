#################################
# Sonal Karmakar                #
# sonalkarmakar00@gmail.com     #
# sonal.karmakar@protonmail.com #
#################################

# django_app/config/wsgi.py
import os

from django.core.wsgi import get_wsgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings.staging")
application = get_wsgi_application()
