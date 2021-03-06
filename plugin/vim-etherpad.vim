
" Avoid reloading
if exists('g:loaded_vim_etherpad') || &cp
  finish
endif
let g:loaded_vim_etherpad = 1

" Global configuration options
let g:epad_pad = "test"
let g:epad_host = "localhost"
let g:epad_port = "9001"
let g:epad_path = "p/"
let g:epad_verbose = 0 " set to 1 for low verbosity, 2 for debug verbosity
let g:epad_authors = 1 " set to 1 for showing authors
let g:epad_attributes = 1 " set to 1 for showing attributes
let g:epad_updatetime = 500

python << EOS
import difflib
import logging
log = logging.getLogger('vim_etherpad')
import vim
import sys
import os

path = os.path.dirname(vim.eval('expand("<sfile>")'))

try:
    from socketIO_client import SocketIO
    from py_etherpad import EtherpadIO, Style
except ImportError:
    log.debug("Import locally")
    sys.path += [os.path.join(path, "../pylibs/socketIO-client/"), 
                 os.path.join(path, "../pylibs/PyEtherpadLite/src/")]
    from socketIO_client import SocketIO
    from py_etherpad import EtherpadIO, Style

global pyepad_env
global attr_trans

pyepad_env = {'epad': None,
              'text': None,
              'updated': False,
              'new_rev': None,
              'updatetime': 0,
              'insert': False,
              'changedtick': 0,
              'disconnect': False,
              'status_attr': False,
              'status_auth': False,
              'colors': [],
              'cursors': []}

attr_trans = {'bold':          'bold',
              'italic':        'italic',
              'underline':     'underline',
              'strikethrough': 'undercurl',
              'list':          'list'}

def excepthook(*args): # {{{
    pyepad_env['disconnect'] = True
    vim.command('au! EpadHooks')
    log.error("exception caught: disconnect", exc_info=args)
sys.excepthook = excepthook
# }}}

def calculate_fg(bg): # {{{
    # http://stackoverflow.com/questions/3942878/how-to-decide-font-color-in-white-or-black-depending-on-background-color
    if bg.startswith('#'):
        r, g, b = (int(bg[1:3], 16), int(bg[3:5], 16), int(bg[5:-1], 16))
        if (r*0.299+b*0.587+g*0.114) > 50:
            return "#000000"
    return "#ffffff"
# }}}

def calculate_bright(color): # {{{
    if color.startswith('#'):
        r, g, b =  (int(color[1:3], 16)+64, int(color[3:5], 16)+64, int(color[5:], 16)+64)
        if r > 255: r = 0xff
        if g > 255: g = 0xff
        if b > 255: b = 0xff
        return "#%02x%02x%02x" % (r, g, b)
    return "#000000"
# }}}
        

def _update_buffer(): # {{{
    """
    This function is polled by vim to updated its current buffer
    """
    log.debug("_update_buffer(udated:%s, new_rev:'%s')" % (pyepad_env['updated'], pyepad_env['new_rev']))
    if pyepad_env['disconnect']:
        vim.command('augroup! EpadHooks')
        vim.command('set updatetime='+pyepad_env['updatetime'])
        #vim.command('set buftype='+pyepad_env['buftype'])
        for hilight in pyepad_env['colors']:
            vim.command('syn clear %s' % hilight)
        for i in pyepad_env['cursors']:
            vim.command('call matchdelete(%s)' % (i))
        pyepad_env['disconnect'] = False

    if pyepad_env['new_rev']:
        pyepad_env['epad'].patch_text(*pyepad_env['new_rev'])
        pyepad_env['new_rev'] = None

    if pyepad_env['updated']:
        text_obj = pyepad_env['text']
        text_str = pyepad_env['text'].decorated(style=Style.STYLES['Raw']())
        pyepad_env['buffer'][:] = [l.encode('utf-8') for l in text_str.splitlines()]
        if pyepad_env['insert']:
            vim.command('set buftype=nofile')
        vim.command("set nomodified")
        c, l = (1, 1)
        for hilight in pyepad_env['colors']:
            vim.command('syn clear %s' % hilight)
        for i in pyepad_env['cursors']:
            vim.command('call matchdelete(%s)' % (i))
        pyepad_env['cursors'] = []
        for i in range(0, len(text_obj)):
            attr = text_obj.get_attr(i)
            color = text_obj.get_author_color(i)
            cursor = text_obj.get_cursor(c-1, l-1)
            if cursor:
                cursorcolor = text_obj._authors.get_color(cursor)
                cursorcolor = calculate_bright(cursorcolor)
                cursorname = "Epad"+ cursorcolor[1:]
                pyepad_env['colors'].append(cursorname)
                vim.command('hi %(cname)s guibg=%(bg)s '\
                            'guifg=%(fg)s ' % dict(cname=cursorname, 
                                                    fg=calculate_fg(cursorcolor),
                                                    bg=cursorcolor))
            if color:
                # because colors can't be combined, here is a workaround,
                # see http://stackoverflow.com/questions/15974439/superpose-two-vim-syntax-matches-on-the-same-character
                if len(attr) > 0:
                    vimattr = map(lambda x: x[0], sorted(attr))
                    colorname = "Epad"+ color[1:] + "_" + reduce(lambda x, y: x+y.capitalize(), vimattr)
                    vimattr = ",".join([attr_trans[attr] for attr in vimattr])
                    if not colorname in pyepad_env['colors'] and vim.eval('g:epad_authors') != "0":
                        pyepad_env['colors'].append(colorname)
                        vim.command('hi %(cname)s guibg=%(bg)s '\
                                    'guifg=%(fg)s gui=%(attr)s '\
                                    'term=%(attr)s' % dict(cname=colorname, 
                                                           fg=calculate_fg(color),
                                                           bg=color,
                                                           attr=vimattr))
                    else:
                        pyepad_env['colors'].append(colorname)
                        vim.command('hi %(cname)s '\
                                    ' gui=%(attr)s term=%(attr)s' % dict(cname=colorname,
                                                                         attr=vimattr))
                else:
                    colorname = "Epad"+ color[1:]
                    if not colorname in pyepad_env['colors']:
                        pyepad_env['colors'].append(colorname)
                        vim.command('hi %(cname)s guibg=%(bg)s '\
                                     'guifg=%(fg)s' % dict(cname=colorname, 
                                                           fg=calculate_fg(color),
                                                           bg=color))
                if cursor:
                    pyepad_env['cursors'].append(vim.eval("matchadd('%s', '%s')" % (cursorname,
                                                                    '\%'+str(l)+'l\%'+str(c)+'c')
                                                ))
                elif vim.eval('g:epad_attributes') != "0" and vim.eval('g:epad_authors') != "0":
                    vim.command('syn match %s ' % (colorname,)
                                +'/\%'+str(l)+'l\%'+str(c)+'c\(.\|$\)/')
            c += 1
            if text_obj.get_char(i) == '\n':
                l += 1
                c = 1
        vim.command('redraw!')
        pyepad_env['updated'] = False
# }}}

def _launch_epad(padid=None, verbose=None, *args): # {{{
    """
    launches EtherpadLiteClient
    """
    def parse_args(padid): # {{{
        protocol, padid = padid.split('://')
        secure = False
        port = "80"
        if protocol == "https":
            secure = True
            port = "443"
        padid = padid.split('/')
        host = padid[0]
        if ':' in host:
            host, port = host.split(':')
        path = ""
        if len(padid) > 2:
            path = "/".join(padid[1:-1])+'/'
        padid = padid[-1]
        return secure, host, port, path, padid
    # }}}

    def vim_link(text): # {{{
        """
        callback function that is called by EtherpadLiteClient
        it stores the last updated text
        """
        if not text is None:
            pyepad_env['text'] = text
            pyepad_env['updated'] = True
    # }}}

    def on_disconnect(): # {{{
        """
        callback function that is called by EtherpadLiteClient 
        on disconnection of the Etherpad Lite Server
        """
        vim.command('echohl ErrorMsg')
        vim.command('echo "disconnected from Etherpad"')
        vim.command('echohl None')
        pyepad_env['disconnect'] = True
    # }}}

    host = vim.eval('g:epad_host')
    port = vim.eval('g:epad_port')
    path = vim.eval('g:epad_path')
    secure = False
    if padid:
        if not padid.startswith('http'):
            padid = padid
        else:
            secure, host, port, path, padid = parse_args(padid)
    else:
        padid = vim.eval('g:epad_pad')

    if not verbose:
        verbose = vim.eval('g:epad_verbose')
    verbose = int(verbose)

    logging.basicConfig()
    if verbose:
        if verbose is 1:
            logging.root.setLevel(logging.INFO)
        elif verbose is 2:
            logging.root.setLevel(logging.DEBUG)
        else:
            logging.root.setLevel(logging.WARN)
    else:
        logging.root.setLevel(logging.WARN)

    # disable cursorcolumn and cursorline that interferes with syntax
    vim.command('set nocursorcolumn')
    vim.command('set nocursorline')
    #pyepad_env['buftype'] = vim.eval('&buftype')
    #vim.command('set buftype=nofile')
    pyepad_env['updatetime'] = vim.eval('&updatetime')
    vim.command('set updatetime='+vim.eval('g:epad_updatetime'))
    pyepad_env['changedtick'] = vim.eval('b:changedtick')

    pyepad_env['buffer'] = vim.current.buffer

    try:
        pyepad_env['epad'] = EtherpadIO(padid, vim_link, host, path, port, 
                                        secure, verbose, 
                                        transports=['websocket', 'xhr-polling'], #, 'jsonp-polling'], 
                                        disc_cb=on_disconnect)

        if not pyepad_env['epad'].has_ended():
            vim.command('echomsg "connected to Etherpad: %s://%s:%s/%s%s"' % ('https' if secure else 'http', host, port, path, padid))
        else:
            vim.command('echohl ErrorMsg')
            vim.command('echo "not connected to Etherpad"')
            vim.command('echohl None')

    except Exception, err:
        log.exception(err)
        vim.command('echohl ErrorMsg')
        vim.command('echo "Couldn\'t connect to Etherpad: %s://%s:%s/%s%s"' % ('https' if secure else 'http', host, port, path, padid))
        vim.command('echohl None')

    vim.command('call EpadHooks()')
# }}}

def _pause_epad(): # {{{
    """
    Function that pauses EtherpadLiteClient
    """
    log.debug("_pause_epad()")
    if not pyepad_env['epad'].has_ended():
        pyepad_env['epad'].pause()
    else:
        vim.command('echohl ErrorMsg')
        vim.command('echo "not connected to Etherpad"')
        vim.command('echohl None')
# }}}

def _vim_to_epad_update(): # {{{
    """
    Function that sends all buffers updates to the EtherpadLite server
    """
    log.debug("_vim_to_epad_update()")
    if not pyepad_env['updated'] and len(pyepad_env['buffer']) > 1:
        if not pyepad_env['epad'].has_ended() and pyepad_env['text']:
            if str(pyepad_env['text']) != "\n".join(pyepad_env['buffer'][:])+"\n":
                if pyepad_env['insert']:
                    vim.command('set buftype=')
                vim.command("set modified")
                pyepad_env['new_rev'] = (pyepad_env['text'], "\n".join(pyepad_env['buffer'][:])+"\n")
        else:
            vim.command('echohl ErrorMsg')
            vim.command('echo "not connected to Etherpad"')
            vim.command('echohl None')
# }}}


def _stop_epad(*args): # {{{
    """
    Function that disconnects EtherpadLiteClient from the server
    """
    log.debug("_stop_epad()")
    if pyepad_env['epad'] and not pyepad_env['epad'].has_ended():
        pyepad_env['epad'].stop()
# }}}

def _toggle_attributes(*args): # {{{
    log.debug("_toggle_attributes()")
    if len(args) > 0:
        if args[0] == "0":
            vim.command('let g:epad_attributes = 0')
        else:
            vim.command('let g:epad_attributes = 1')
    elif vim.eval('g:epad_attributes') == "0":
        vim.command('let g:epad_attributes = 1')
    else:
        vim.command('let g:epad_attributes = 0')
    pyepad_env['updated'] = True
# }}}

def _toggle_authors(*args): # {{{
    log.debug("_toggle_authors()")
    if len(args) > 0:
        if args[0] == "0":
            vim.command('let g:epad_authors = 0')
        else:
            vim.command('let g:epad_authors = 1')
    elif vim.eval('g:epad_authors') == "0":
        vim.command('let g:epad_authors = 1')
    else:
        vim.command('let g:epad_authors = 0')
    pyepad_env['updated'] = True
# }}}

# {{{
def _detect_and_update_change():
    if pyepad_env['epad'] and not pyepad_env['epad'].has_ended():
        if pyepad_env['insert']:
            check = lambda: vim.eval('b:changedtick') != str(int(pyepad_env['changedtick'])+2)
        else:
            check = lambda: vim.eval('b:changedtick') != pyepad_env['changedtick']
        if check():
            pyepad_env['changedtick'] = vim.eval('b:changedtick')
            _vim_to_epad_update()
        else:
            _update_buffer()
        return True
    return False

# }}}

def _insert_enter(): # {{{
    log.debug("_insert_enter()")
    if not pyepad_env['insert']:
        pyepad_env['insert'] = True
        pyepad_env['status_attr'] = vim.eval('g:epad_attributes')
        pyepad_env['status_auth'] = vim.eval('g:epad_authors')
        _toggle_attributes("0")
        _toggle_authors("0")
        for hilight in pyepad_env['colors']:
            vim.command('syn clear %s' % hilight)
        for i in pyepad_env['cursors']:
            vim.command('call matchdelete(%s)' % (i))
        vim.command('set buftype=nofile')
# }}}

def _normal_enter(): # {{{
    log.debug("_normal_enter()")
    if pyepad_env['insert']:
        pyepad_env['insert'] = False
        _toggle_attributes(pyepad_env['status_attr'])
        _toggle_authors(pyepad_env['status_auth'])
        vim.command('set buftype=')
# }}}

def _normal_timer(): # {{{
    log.debug("_normal_timer()")
    # K_IGNORE keycode does not work after version 7.2.025)
    # there are numerous other keysequences that you can use
    if _detect_and_update_change():
        vim.command('call feedkeys("f\e")')
# }}}

def _insert_timer(): # {{{
    log.debug("_insert_timer()")
    if _detect_and_update_change():
        # K_IGNORE keycode does not work after version 7.2.025)
        # there are numerous other keysequences that you can use
        vim.command(':call feedkeys("a\<Backspace>")')
# }}}

EOS

command! -nargs=* Etherpad :python _launch_epad(<f-args>)
command! -nargs=* EtherpadStop :python _stop_epad(<f-args>)
command! -nargs=* EtherpadPause :python _pause_epad(<f-args>)
command! -nargs=* EtherpadUpdate :python _vim_to_epad_update(<f-args>)
command! -nargs=* EtherpadShowAttributes :python _toggle_attributes(<f-args>)
command! -nargs=* EtherpadShowAuthors :python _toggle_authors(<f-args>)

function! EpadHooks()
    augroup EpadHooks
        au!
        au CursorHold *   python _normal_timer()
        au InsertLeave *  python _normal_enter()
        au CursorMoved *  python _detect_and_update_change()
        au CursorHoldI *  python _insert_timer()
        au InsertEnter *  python _insert_enter()
        au CursorMovedI * python _detect_and_update_change()
    augroup END
endfunction

" vim: set fdm=marker ts=4 sw=4
