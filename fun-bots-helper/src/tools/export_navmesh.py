from tools.addons.gets import get_it_running, get_tables
from tools.addons.sets import set_navmesh_files


def export_navmesh() -> None:

    connection, cursor = get_tables()
    set_navmesh_files(cursor)
    connection.close()


if __name__ == "__main__":
    get_it_running(export_navmesh)
