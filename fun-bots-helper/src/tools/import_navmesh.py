import sqlite3

from loguru import logger
from tools.addons.gets import get_it_running
from tools.addons.sets import set_navmesh_db


def import_navmesh() -> None:

    # Unlike import_traces (which rebuilds the whole database from scratch), the
    # navmesh import only touches the *_navmesh tables, so it operates directly on
    # mod.db and leaves traces, settings and permissions untouched.
    connection = sqlite3.connect("mod.db")
    cursor = connection.cursor()
    try:
        set_navmesh_db(cursor)
    except KeyboardInterrupt:
        logger.warning("Crtl+C detected! Changes rolled back!")
        connection.rollback()
    else:
        connection.commit()
    finally:
        connection.close()


if __name__ == "__main__":
    get_it_running(import_navmesh)
